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

my $counter = File::Spec->catfile("$tmp", 'counter');
my $log     = File::Spec->catfile("$tmp", 'hypnotoad.log');
my $app     = File::Spec->catfile("$tmp", 'app.pl');

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
	return if $c->buffer_is_cached;

	open(my $fh, '>>', $ENV{MPB_COUNTER}) or die "Cannot write the counter: $!";
	print $fh "$$\n";
	close($fh);

	# Keep the entry cold long enough for the other workers to join
	select(undef, undef, undef, 1);

	$c->render(text => 'cold body');
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

	$ENV{MPB_PORT}       = $port;
	$ENV{MPB_TMP}        = "$tmp";
	$ENV{MPB_CACHE_DIR}  = $cache_dir;
	$ENV{MPB_LOCK_DIR}   = $lock_dir;
	$ENV{MPB_COUNTER}    = $counter;
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
Mojo::Promise->all(map { $client->get_p("$base/cold" => {Connection => 'close'}) } 1 .. 6)
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
