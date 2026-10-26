use strict;
use warnings;

use Test::More;
use Time::HiRes ();

use Mojolicious::Plugin::Buffer::Lock::Redis;

# Optional live integration test.  It is deliberately outside the normal
# unit tests so a checkout without Redis does not fail:
#
#     MPB_REDIS_URL=redis://127.0.0.1:6379 prove -Ilib t/76-live-redis.t
#
# REDIS_URL is accepted as a fallback for environments that already use it.
my $url = $ENV{MPB_REDIS_URL} // $ENV{REDIS_URL};
plan skip_all => 'set MPB_REDIS_URL or REDIS_URL to a running Redis server'
	unless defined($url) && length($url);

eval { require Redis; 1 }
	or plan skip_all => 'install the Redis client to run the live Redis test';

my $server = $url;
$server =~ s{^redis://}{};

my $redis = eval {
	Redis->new(
		server        => $server,
		cnx_timeout   => 1,
		read_timeout  => 1,
		write_timeout => 1,
	);
};
die "Cannot create a Redis client for $url: $@" if $@;

my $pong = eval { $redis->ping };
die "Cannot reach Redis at $url: $@" if $@;
is($pong, 'PONG', 'the live Redis server is reachable');

my $namespace = 'mpb:live:' . $$ . ':' . int(rand(1_000_000)) . ':';
my @keys;

END {
	for my $key (@keys) {
		eval { $redis->del($key) };
	}
}

my $lock = Mojolicious::Plugin::Buffer::Lock::Redis->new(
	redis     => $redis,
	namespace => $namespace,
	ttl       => 5,
);

my ($guard, $error) = $lock->acquire('live-key');
ok($guard, 'the live Redis lock is acquired');
ok(!defined($error), 'no error acquiring the live lock');
push @keys, $guard->{key} if $guard;

if ($guard) {
	my ($blocked, $blocked_error) = $lock->acquire('live-key');
	ok(!$blocked, 'a second live acquisition is blocked');
	ok(!defined($blocked_error), 'a held live lock is not an error');

	my ($released, $release_error) = $lock->release($guard);
	ok($released, 'the live lock is released');
	ok(!defined($release_error), 'no error releasing the live lock');

	my ($again) = $lock->acquire('live-key');
	ok($again, 'the live lock can be acquired again');
	$lock->release($again) if $again;
}

my ($token_guard) = $lock->acquire('token-key');
ok($token_guard, 'a second live lock is acquired for the token test');
if ($token_guard) {
	my $key = $token_guard->{key};
	push @keys, $key;

	# Simulate the lock expiring and another owner taking it.  Releasing
	# the old guard must not delete the other owner's token.
	$redis->set($key, 'another-owner');
	my ($released, $release_error) = $lock->release($token_guard);
	ok($released, 'releasing a stale live guard does not fail');
	ok(!defined($release_error), 'no error releasing the stale live guard');
	is($redis->get($key), 'another-owner', 'the other owner\'s token survived the stale release');
	$redis->del($key);
}

my $short_lock = Mojolicious::Plugin::Buffer::Lock::Redis->new(
	redis     => $redis,
	namespace => $namespace,
	ttl       => 0.4,
);

my ($expiring) = $short_lock->acquire('ttl-key');
ok($expiring, 'a short-lived live lock is acquired');
push @keys, $expiring->{key} if $expiring;

Time::HiRes::sleep(0.6);

my ($after_expiry) = $short_lock->acquire('ttl-key');
ok($after_expiry, 'the live lock expires after its TTL');
$short_lock->release($after_expiry) if $after_expiry;

done_testing();
