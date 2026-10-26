use strict;
use warnings;

use Test::More;
use Config;
use File::Basename qw(dirname);
use File::Spec ();
use File::Temp ();
use IO::Socket::INET;
use Mojo::Promise;
use Mojo::UserAgent;
use POSIX qw(WNOHANG);
use Time::HiRes ();

plan skip_all => 'hypnotoad requires a UNIX-like system' if $^O eq 'MSWin32';

my $hypnotoad;
for my $dir (dirname(File::Spec->rel2abs($^X)), split(/\Q$Config{path_sep}\E/, $ENV{PATH} // '')) {
	next unless defined($dir) && length($dir);
	my $candidate = File::Spec->catfile($dir, 'hypnotoad');
	if (-f $candidate) {
		$hypnotoad = $candidate;
		last;
	}
}
plan skip_all => 'hypnotoad is not installed' unless $hypnotoad;

my $root = dirname(dirname(File::Spec->rel2abs($0)));
my $lib  = File::Spec->catdir($root, 'lib');
plan skip_all => "the distribution lib directory is missing" unless -d $lib;

my $tmp = File::Temp->newdir('mpb-hypnotoad-XXXXXX', TMPDIR => 1);
my $cache_dir = File::Spec->catdir("$tmp", 'cache');
my $lock_dir  = File::Spec->catdir("$tmp", 'locks');
mkdir($cache_dir) or die "Cannot create $cache_dir: $!";

my $probe = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Listen    => 1,
	ReuseAddr => 1,
) or plan skip_all => "Cannot bind a local port: $!";
my $port = $probe->sockport;
close($probe);

my $counter        = File::Spec->catfile("$tmp", 'counter');
my $workers_log    = File::Spec->catfile("$tmp", 'workers');
my $stuck_marker   = File::Spec->catfile("$tmp", 'stuck.marker');
my $release_marker = File::Spec->catfile("$tmp", 'stuck.release');
my $die_marker     = File::Spec->catfile("$tmp", 'die.marker');
my $log            = File::Spec->catfile("$tmp", 'hypnotoad.log');
my $app            = File::Spec->catfile("$tmp", 'app.pl');

my $app_source = <<'APP';
use strict;
use warnings;

use Mojolicious::Lite;
use Mojo::Util ();
use Storable ();

{
	package TestFileCache;

	sub new {
		my ($class, $dir) = @_;
		return bless {dir => $dir}, $class;
	}

	sub _path {
		my ($self, $key) = @_;
		return $self->{dir} . '/' . Mojo::Util::md5_sum($key);
	}

	sub get {
		my ($self, $key) = @_;
		my $path = $self->_path($key);
		return undef unless -f $path;
		return eval { Storable::retrieve($path) };
	}

	sub set {
		my ($self, $key, $value, $duration) = @_;
		my $path = $self->_path($key);
		my $tmp  = "$path.$$." . int(rand(1_000_000));
		return 0 unless eval { Storable::nstore($value, $tmp); 1 };
		return 1 if rename($tmp, $path);
		unlink($tmp);
		return 0;
	}

	sub remove {
		my ($self, $key) = @_;
		return unlink($self->_path($key)) ? 1 : 0;
	}
}

plugin 'Buffer' => {
	cache              => TestFileCache->new($ENV{MPB_CACHE_DIR}),
	cache_lock_dir     => $ENV{MPB_LOCK_DIR},
	cache_lock_timeout => 5,
	last_modified      => 0,
};

get '/ping' => sub {
	my $c = shift;
	$c->render(text => 'pong');
};

get '/cold' => sub {
	my $c = shift;

	# Record the handling worker before buffer_is_cached(), so waiters and
	# cache hits are counted as well as the request that builds the entry.
	open(my $log, '>>', $ENV{MPB_WORKERS}) or die "Cannot write the worker log: $!";
	print $log join(' ', $$, ($c->req->headers->header('X-Test-Id') // '')), "\n";
	close($log);

	return if $c->buffer_is_cached;

	open(my $fh, '>>', $ENV{MPB_COUNTER}) or die "Cannot write the counter: $!";
	print $fh "$$\n";
	close($fh);

	# Keep the entry cold long enough for the other workers to join
	select(undef, undef, undef, 1);

	$c->render(text => 'cold body');
};

get '/stuck' => sub {
	my $c = shift;
	$c->stash(buffer => {cache_key => 'stuck-key'});
	return if $c->buffer_is_cached;

	open(my $fh, '>', $ENV{MPB_STUCK_MARKER}) or die "Cannot write the marker: $!";
	print $fh "$$\n";
	close($fh);

	# Hold the shared lock until the test explicitly releases it, so the
	# waiter is guaranteed to time out rather than race a fixed sleep.
	my $deadline = time + 10;
	while (!-e $ENV{MPB_RELEASE_MARKER} && (time < $deadline)) {
		select(undef, undef, undef, 0.05);
	}

	$c->render(text => 'stuck body');
};

get '/waiter' => sub {
	my $c = shift;
	$c->stash(buffer => {
		cache_key => 'stuck-key',
		cache_lock_timeout => 0.5,
	});
	return if $c->buffer_is_cached;
	$c->render(text => 'the waiter ran instead of waiting');
};

get '/die' => sub {
	my $c = shift;
	$c->stash(buffer => {cache_key => 'die-key'});
	return if $c->buffer_is_cached;

	open(my $fh, '>', $ENV{MPB_DIE_MARKER}) or die "Cannot write the marker: $!";
	print $fh "$$\n";
	close($fh);

	# A worker killed by a signal cannot run cleanup code; the kernel must
	# release its flock so another worker can rebuild the entry.
	kill('KILL', $$) or die "Cannot kill this worker: $!";
	$c->render(text => 'the worker did not die');
};

get '/recover' => sub {
	my $c = shift;
	$c->stash(buffer => {
		cache_key => 'die-key',
		cache_lock_timeout => 1,
	});
	return if $c->buffer_is_cached;
	$c->render(text => 'recovered body');
};

app->config(hypnotoad => {
	listen           => ["http://127.0.0.1:$ENV{MPB_PORT}"],
	workers          => 3,
	spare            => 0,
	pid_file         => "$ENV{MPB_TMP}/hypnotoad.pid",
	graceful_timeout => 2,
});

app->start;
APP

write_file($app, $app_source);

my ($server_pid, $server_group) = (0, 0);

sub stop_server {
	return unless $server_pid;
	my $pid = $server_pid;
	$server_pid = 0;
	return unless $server_group;

	kill('TERM', -$pid);
	my $deadline = Time::HiRes::time() + 3;
	while (Time::HiRes::time() < $deadline) {
		last unless kill(0, -$pid);
		Time::HiRes::sleep(0.1);
	}
	kill('KILL', -$pid) if kill(0, -$pid);
	waitpid($pid, WNOHANG);

	return;
}

END { stop_server() }

pipe(my $ready_reader, my $ready_writer) or die "Cannot create a pipe: $!";
$server_pid = fork;
defined($server_pid) or die "Cannot fork: $!";

if (!$server_pid) {
	close($ready_reader);
	open(STDIN, '<', File::Spec->devnull) or POSIX::_exit(1);
	open(STDOUT, '>', $log) or POSIX::_exit(1);
	open(STDERR, '>&', STDOUT) or POSIX::_exit(1);

	if (POSIX::setsid() < 0) {
		print STDERR "setsid failed: $!\n";
		POSIX::_exit(1);
	}
	print {$ready_writer} "1";
	close($ready_writer);

	$ENV{MPB_PORT}           = $port;
	$ENV{MPB_TMP}            = "$tmp";
	$ENV{MPB_CACHE_DIR}      = $cache_dir;
	$ENV{MPB_LOCK_DIR}       = $lock_dir;
	$ENV{MPB_COUNTER}        = $counter;
	$ENV{MPB_WORKERS}        = $workers_log;
	$ENV{MPB_STUCK_MARKER}   = $stuck_marker;
	$ENV{MPB_RELEASE_MARKER} = $release_marker;
	$ENV{MPB_DIE_MARKER}     = $die_marker;
	$ENV{PERL5LIB}       = join(':', $lib, grep { defined($_) && length($_) } ($ENV{PERL5LIB} // ''));
	$ENV{HYPNOTOAD_FOREGROUND} = 1;
	delete @ENV{qw(HYPNOTOAD_EXE HYPNOTOAD_APP HYPNOTOAD_PID HYPNOTOAD_REV)};

	exec($^X, $hypnotoad, '-f', $app) or do {
		print STDERR "exec failed: $!\n";
		POSIX::_exit(1);
	};
}

close($ready_writer);
my $ready_byte = <$ready_reader>;
close($ready_reader);
$server_group = defined($ready_byte) && ($ready_byte eq '1');

if (!$server_group) {
	waitpid($server_pid, 0);
	$server_pid = 0;
	fail(failure_message('hypnotoad did not start'));
	done_testing();
	return;
}

my $base = "http://127.0.0.1:$port";
my $ua   = Mojo::UserAgent->new(connect_timeout => 1, request_timeout => 2);
my $ready = 0;
my $deadline = Time::HiRes::time() + 15;
while (Time::HiRes::time() < $deadline) {
	my $tx = $ua->get("$base/ping" => {Connection => 'close'});
	if ($tx->res && $tx->res->is_success && ($tx->res->code == 200)) {
		$ready = 1;
		last;
	}
	last unless kill(0, -$server_pid);
	Time::HiRes::sleep(0.1);
}
undef $ua;

if (!$ready) {
	fail(failure_message('hypnotoad did not become ready'));
	stop_server();
	done_testing();
	return;
}

# Let the master finish forking every worker
Time::HiRes::sleep(0.2);

my $client = Mojo::UserAgent->new(
	connect_timeout => 2,
	request_timeout => 10,
	max_connections => 20,
);
my (@tx, $error);
Mojo::Promise->all(map {
	$client->get_p("$base/cold" => {Connection => 'close', 'X-Test-Id' => $_})
} 1 .. 6)
	->then(sub { @tx = map { @$_ } @_ })
	->catch(sub { $error = shift })
	->wait;

ok(!defined($error), 'all concurrent requests completed') or diag("Request failed: $error");
is(scalar(@tx), 6, 'six responses');
is_deeply([map { $_->res ? $_->res->code : 0 } @tx], [(200) x 6], 'every response is 200');
is_deeply([map { $_->res ? $_->res->body : undef } @tx], [('cold body') x 6], 'every response has the page');

my @cache = map { $_->res ? $_->res->headers->header('X-Cache') : undef } @tx;
is(scalar(grep { defined($_) && ($_ eq 'MISS') } @cache), 1, 'one request built the entry');
is(scalar(grep { defined($_) && ($_ eq 'HIT') } @cache), 5, 'the other requests replayed it');

my @handled;
if (open(my $fh, '<', $workers_log)) {
	@handled = grep { /\S/ } <$fh>;
	close($fh);
} else {
	fail("Cannot read the worker log: $!");
}
is(scalar(@handled), 6, 'every concurrent request recorded its worker');

my (%worker_pids, %request_ids);
for my $line (@handled) {
	my ($pid, $id) = split(/\s+/, $line);
	$worker_pids{$pid} = 1 if defined($pid) && length($pid);
	$request_ids{$id} = 1 if defined($id) && length($id);
}
cmp_ok(scalar(keys %worker_pids), '>', 1,
	'concurrent cold requests were served by more than one worker pid');
is_deeply([sort { $a <=> $b } keys %request_ids], [1 .. 6], 'every request was accounted for');

my @runs;
if (open(my $fh, '<', $counter)) {
	@runs = grep { /\S/ } <$fh>;
	close($fh);
} else {
	fail("Cannot read the counter: $!");
}
is(scalar(@runs), 1, 'the action ran exactly once across all workers');

diag("Server log:\n" . read_file($log))
	if defined($error) || (grep { !$_->res || !$_->res->is_success || ($_->res->code != 200) } @tx);

# A builder that holds the shared lock past the waiter's timeout.  The
# builder runs in a child process so this process can send the waiter request
# while the action is still sleeping in one of the hypnotoad workers.
unlink($stuck_marker);
unlink($release_marker);
pipe(my $builder_reader, my $builder_writer) or die "Cannot create a pipe: $!";
my $builder_pid = fork;
defined($builder_pid) or die "Cannot fork: $!";

if (!$builder_pid) {
	close($builder_reader);
	my $builder_ua = Mojo::UserAgent->new(connect_timeout => 2, request_timeout => 10);
	my $tx = $builder_ua->get("$base/stuck" => {Connection => 'close'});
	my $code = $tx->res ? $tx->res->code : 0;
	print {$builder_writer} "$code\n";
	close($builder_writer);
	POSIX::_exit(0);
}

close($builder_writer);

my $stuck_deadline = Time::HiRes::time() + 5;
while (!-e $stuck_marker && Time::HiRes::time() < $stuck_deadline) {
	Time::HiRes::sleep(0.05);
}
my $holding = -e $stuck_marker;
ok($holding, 'the builder acquired the shared lock') or diag("Server log:\n" . read_file($log));

my ($waiter_res, $waiter_elapsed);
if ($holding) {
	my $started = Time::HiRes::time();
	my $waiter_tx = $client->get("$base/waiter" => {Connection => 'close'});
	$waiter_elapsed = Time::HiRes::time() - $started;
	$waiter_res = $waiter_tx->res;
}

# Let the builder finish even if the waiter check failed, so the child cannot
# keep holding a worker until its own timeout.
open(my $release_fh, '>', $release_marker) or die "Cannot release the builder: $!";
close($release_fh);

my $builder_line = <$builder_reader>;
close($builder_reader);
waitpid($builder_pid, 0);
chomp($builder_line) if defined($builder_line);
is($builder_line, 200, 'the builder completed normally after holding the lock');

if ($holding) {
	my $waiter_code = $waiter_res ? $waiter_res->code : 0;
	is($waiter_code, 503, 'the waiter received 503 when the builder held the lock past its timeout');
	is($waiter_res ? $waiter_res->headers->header('Retry-After') : undef, 1, 'the waiter was told to retry');
	is($waiter_res ? $waiter_res->headers->header('X-Cache') : undef, 'MISS', 'the waiter did not get a cached response');
	like($waiter_res ? $waiter_res->body : '', qr/being generated/, 'the waiter received the retry page');
	cmp_ok($waiter_elapsed, '<', 2.5, 'the waiter timed out before the builder released the lock');

	my $after_tx = $client->get("$base/waiter" => {Connection => 'close'});
	is($after_tx->res->code, 200, 'the cache entry is available after the builder finishes');
	is($after_tx->res->headers->header('X-Cache'), 'HIT', 'the finished entry is replayed');
	is($after_tx->res->body, 'stuck body', 'the cached builder body is served');
}

# A worker killed while holding the lock cannot run release code.  The kernel
# must close its lock file, so a remaining worker can build the same key.
unlink($die_marker);
my $die_tx = $client->get("$base/die" => {Connection => 'close'});
my $die_code = $die_tx->res ? ($die_tx->res->code // 0) : 0;
ok($die_code != 200, 'the dying builder did not return a page');

my $die_pid;
if (open(my $fh, '<', $die_marker)) {
	$die_pid = <$fh>;
	close($fh);
	chomp($die_pid) if defined($die_pid);
}
ok(defined($die_pid) && ($die_pid =~ /^\d+$/), 'the dying builder recorded its worker pid')
	or diag("Server log:\n" . read_file($log));

my $dead = 0;
if (defined($die_pid) && ($die_pid =~ /^\d+$/)) {
	my $deadline = Time::HiRes::time() + 5;
	while (Time::HiRes::time() < $deadline) {
		if (!kill(0, $die_pid)) {
			$dead = 1;
			last;
		}
		Time::HiRes::sleep(0.05);
	}
}
ok($dead, 'the worker exited and the kernel released its file locks') or diag("Server log:\n" . read_file($log));

if ($dead) {
	my $recover_tx = $client->get("$base/recover" => {Connection => 'close'});
	is($recover_tx->res->code, 200, 'a remaining worker rebuilt the abandoned key');
	is($recover_tx->res->headers->header('X-Cache'), 'MISS', 'the recovering request was a miss');
	is($recover_tx->res->body, 'recovered body', 'the remaining worker served its own page');

	my $again_tx = $client->get("$base/recover" => {Connection => 'close'});
	is($again_tx->res->code, 200, 'the recovered entry is available');
	is($again_tx->res->headers->header('X-Cache'), 'HIT', 'the recovered entry is replayed');
	is($again_tx->res->body, 'recovered body', 'the recovered body is cached');
}

stop_server();
done_testing();

sub write_file {
	my ($path, $content) = @_;

	open(my $fh, '>', $path) or die "Cannot write $path: $!";
	print $fh $content;
	close($fh) or die "Cannot close $path: $!";

	return;
}

sub read_file {
	my $path = shift;

	open(my $fh, '<', $path) or return '';
	local $/;
	my $content = <$fh>;
	close($fh);

	return $content // '';
}

sub failure_message {
	my $message = shift;
	my $output  = read_file($log);

	return $message . (length($output) ? ":\n$output" : '');
}
