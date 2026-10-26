use strict;
use warnings;

use Test::More;
use File::Temp ();
use Mojo::IOLoop;
use Mojo::Util ();
use Mojolicious;
use POSIX ();
use Storable ();
use Time::HiRes ();
use Test::Mojo;

use Mojolicious::Plugin::Buffer;

{
	package TestCache;

	sub new { bless {data => {}, sets => 0}, shift }

	sub get {
		my ($self, $key) = @_;
		return $self->{data}{$key};
	}

	sub set {
		my ($self, $key, $value, $duration) = @_;
		$self->{data}{$key} = $value;
		$self->{sets}++;
		return 1;
	}

	sub remove {
		my ($self, $key) = @_;
		delete $self->{data}{$key};
		return 1;
	}
}

# A cache that really lives in files, so that a separate process can fill it
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
		my $ok = eval { Storable::nstore($value, $tmp); 1 };
		return 0 unless $ok;
		return 1 if rename($tmp, $path);
		unlink($tmp);
		return 0;
	}

	sub remove {
		my ($self, $key) = @_;
		return unlink($self->_path($key)) ? 1 : 0;
	}
}

my $lock_temp = File::Temp->newdir('mpb-locks-XXXXXX', TMPDIR => 1);
my $lock_dir  = "$lock_temp";

sub build_app {
	my (%options) = @_;

	my $app = Mojolicious->new;
	$app->log->level('error');
	$app->plugin('Buffer', %options);
	$app->{runs} = 0;

	$app->routes->get('/shared' => sub {
		my $c = shift;
		$c->stash(buffer => {cache_key => 'shared-key'});
		return if $c->buffer_is_cached;
		$app->{runs}++;
		$c->render(text => 'local run');
	});

	return $app;
}

subtest 'the file lock is exclusive and released' => sub {
	my ($first, $error) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'unit-key');
	ok($first, 'the first lock is acquired');
	ok(!defined($error), 'no error for the first lock');

	my ($second, $second_error) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'unit-key');
	ok(!$second, 'a second lock is blocked');
	ok(!defined($second_error), 'a held lock is not reported as an error');

	Mojolicious::Plugin::Buffer::_release_lock($first);
	my ($third, $third_error) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'unit-key');
	ok($third, 'the lock can be acquired after release');
	ok(!defined($third_error), 'no error after release');
	Mojolicious::Plugin::Buffer::_release_lock($third);
};

subtest 'a waiter picks up an entry from another worker' => sub {
	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app(
		cache => $cache,
		cache_lock_dir => $lock_dir,
		cache_lock_timeout => 2,
	));

	my ($guard) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
	ok($guard, 'another worker holds the lock');

	Mojo::IOLoop->timer(0.3 => sub {
		$cache->set('shared-key', {
			body => 'from another worker',
			status => 200,
			created => time,
			headers => [['Content-Type', 'text/html;charset=UTF-8']],
		}, '1 minute');
		Mojolicious::Plugin::Buffer::_release_lock($guard);
	});

	$t->get_ok('/shared')->status_is(200)->header_is('X-Cache' => 'HIT');
	is($t->tx->res->body, 'from another worker', 'the waiting request got the other worker\'s entry');
	is($t->app->{runs}, 0, 'the local action did not run');

	my ($free) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
	ok($free, 'the lock is free after the wait');
	Mojolicious::Plugin::Buffer::_release_lock($free);
};

subtest 'a waiter gives up when the other worker releases without caching' => sub {
	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app(
		cache => $cache,
		cache_lock_dir => $lock_dir,
		cache_lock_timeout => 2,
	));

	my ($guard) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
	ok($guard, 'another worker holds the lock');
	Mojo::IOLoop->timer(0.3 => sub { Mojolicious::Plugin::Buffer::_release_lock($guard) });

	my $started = Time::HiRes::time();
	$t->get_ok('/shared')->status_is(503)->header_is('Retry-After' => 1);
	my $elapsed = Time::HiRes::time() - $started;
	cmp_ok($elapsed, '<', 1.5, 'the waiter gave up after the lock was released');
	is($t->app->{runs}, 0, 'the local action did not run');
	is($cache->{sets}, 0, 'nothing was cached');
};

subtest 'a waiter times out while another worker holds the lock' => sub {
	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app(
		cache => $cache,
		cache_lock_dir => $lock_dir,
		cache_lock_timeout => 0.3,
	));

	my ($guard) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
	ok($guard, 'another worker holds the lock');

	my $started = Time::HiRes::time();
	$t->get_ok('/shared')->status_is(503);
	my $elapsed = Time::HiRes::time() - $started;
	cmp_ok($elapsed, '<', 1.5, 'the waiter timed out');
	is($t->app->{runs}, 0, 'the local action did not run');

	Mojolicious::Plugin::Buffer::_release_lock($guard);
};

subtest 'the lock is released after a normal request' => sub {
	my $cache = TestCache->new;
	my $t = Test::Mojo->new(build_app(
		cache => $cache,
		cache_lock_dir => $lock_dir,
		cache_lock_timeout => 2,
	));

	$t->get_ok('/shared')->status_is(200)->header_is('X-Cache' => 'MISS');
	is($t->app->{runs}, 1, 'the local action built the entry');

	my ($free) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
	ok($free, 'the lock was released');
	Mojolicious::Plugin::Buffer::_release_lock($free);

	$t->get_ok('/shared')->status_is(200)->header_is('X-Cache' => 'HIT');
	is($t->app->{runs}, 1, 'the second request hit the cache');
};

subtest 'a waiter picks up an entry written by another process' => sub {
	plan skip_all => 'requires fork' if $^O eq 'MSWin32';

	my $dir = File::Temp->newdir('mpb-xproc-XXXXXX', TMPDIR => 1);
	my $cache_dir = "$dir/cache";
	mkdir($cache_dir) or die "mkdir $cache_dir: $!";
	my $cache = TestFileCache->new($cache_dir);

	pipe(my $reader, my $writer) or die "pipe: $!";
	my $pid = fork;
	defined($pid) or die "fork: $!";

	if (!$pid) {
		close($reader);
		my ($lock) = Mojolicious::Plugin::Buffer::_acquire_lock($lock_dir, 'shared-key');
		print {$writer} ($lock ? "locked\n" : "failed\n");
		if (!$lock) {
			close($writer);
			POSIX::_exit(1);
		}

		# Give the other worker time to start waiting, then fill the entry
		select(undef, undef, undef, 0.4);
		$cache->set('shared-key', {
			body => 'from another process',
			status => 200,
			created => time,
			headers => [['Content-Type', 'text/html;charset=UTF-8']],
		}, '1 minute');
		Mojolicious::Plugin::Buffer::_release_lock($lock);
		print {$writer} "done\n";
		close($writer);
		POSIX::_exit(0);
	}

	close($writer);
	my $line = <$reader>;
	is($line, "locked\n", 'the other process holds the lock');

	if ($line eq "locked\n") {
		my $t = Test::Mojo->new(build_app(
			cache => $cache,
			cache_lock_dir => $lock_dir,
			cache_lock_timeout => 3,
		));

		$t->get_ok('/shared')->status_is(200)->header_is('X-Cache' => 'HIT');
		is($t->tx->res->body, 'from another process', 'the entry came from the other process');
		is($t->app->{runs}, 0, 'the local action did not run');
	}

	is(scalar(<$reader>), "done\n", 'the other process finished cleanly');
	close($reader);
};

subtest 'cache_lock_dir is created and validated' => sub {
	my $nested = "$lock_dir/nested/sub";
	my $cache = TestCache->new;
	build_app(cache => $cache, cache_lock_dir => $nested);
	ok(-d $nested, 'the lock directory was created');

	my $file = "$lock_dir/not-a-directory";
	open(my $fh, '>', $file) or die $!;
	close($fh);
	eval { build_app(cache => $cache, cache_lock_dir => $file) };
	like($@, qr/cache_lock_dir/, 'a file is not accepted as the lock directory');

	eval { build_app(cache => $cache, cache_lock_dir => \$lock_dir) };
	like($@, qr/cache_lock_dir must be a directory path/, 'a reference is rejected');
};

done_testing();
