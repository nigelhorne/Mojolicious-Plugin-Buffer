package Mojolicious::Plugin::Buffer::Lock::Redis;

use Mojo::Base -base;

use Carp qw(croak);
use Mojo::Util qw(md5_sum);
use Scalar::Util qw(blessed refaddr);
use Time::HiRes ();

has redis     => undef;
has namespace => 'buffer:lock:';
has ttl       => 60;

my $TOKEN_COUNTER = 0;

# SET NX PX is atomic, so only one worker can create the key.  The token lets
# the owner release exactly its own lock.
my $ACQUIRE_SCRIPT = <<'LUA';
if redis.call('set', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
    return 1
end
return 0
LUA

# Compare and delete in one script, so a lock that expired and was taken by
# another worker is never removed by the previous owner.
my $RELEASE_SCRIPT = <<'LUA';
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
LUA

sub new {
	my ($class, @args) = @_;

	my $self = $class->SUPER::new(@args);
	my $redis = $self->redis;
	# CPAN Redis dispatches commands through AUTOLOAD rather than defining
	# an eval() method, so can('eval') alone would reject a valid client.
	croak 'Mojolicious::Plugin::Buffer: cache_lock redis must be an object with an eval() method or a code reference returning one'
		unless ref($redis) eq 'CODE'
		|| (blessed($redis) && ($redis->can('eval') || $redis->can('AUTOLOAD')));

	my $namespace = $self->namespace;
	croak 'Mojolicious::Plugin::Buffer: cache_lock namespace must be a non-empty string'
		if !defined($namespace) || ref($namespace) || !length($namespace);

	my $ttl = $self->ttl;
	croak 'Mojolicious::Plugin::Buffer: cache_lock ttl must be a positive number of seconds'
		if !defined($ttl) || ref($ttl) || $ttl !~ /^\d+(?:\.\d+)?$/ || $ttl <= 0;

	return $self;
}

sub acquire {
	my ($self, $key) = @_;

	return (undef, 'cache key is not defined') unless defined($key);

	my $lock_key = $self->_key($key);
	my $token    = $self->_token;
	my $ttl      = int($self->ttl * 1000);
	$ttl = 1 if $ttl < 1;

	my $result = eval {
		my $redis = $self->_client;
		die "Redis client factory returned no client\n" unless $redis;
		$redis->eval($ACQUIRE_SCRIPT, 1, $lock_key, $token, $ttl);
	};
	if (my $error = $@) {
		chomp($error);
		return (undef, "Redis lock failed: $error");
	}
	return (undef, 'Redis lock command returned no result') unless defined($result);

	return ({key => $lock_key, token => $token}, undef) if $result;
	return (undef, undef);
}

sub release {
	my ($self, $guard) = @_;

	return (0, 'invalid lock guard')
		unless ref($guard) eq 'HASH' && defined($guard->{key}) && defined($guard->{token});

	my $result = eval {
		my $redis = $self->_client;
		die "Redis client factory returned no client\n" unless $redis;
		$redis->eval($RELEASE_SCRIPT, 1, $guard->{key}, $guard->{token});
	};
	if (my $error = $@) {
		chomp($error);
		return (0, "Redis unlock failed: $error");
	}

	return (1, undef);
}

sub _client {
	my $self = shift;

	my $redis = $self->redis;
	return $redis unless ref($redis) eq 'CODE';

	# Called lazily, so a pre-forking server gets one connection per worker
	return $self->{client} //= $redis->();
}

sub _key {
	my ($self, $key) = @_;

	return $self->namespace . md5_sum($key);
}

sub _token {
	my $self = shift;

	return md5_sum(join "\0", $$, Time::HiRes::time(), ++$TOKEN_COUNTER, rand(), refaddr($self));
}

1;

=head1 NAME

Mojolicious::Plugin::Buffer::Lock::Redis - Redis-backed lock backend

=head1 SYNOPSIS

    use Redis;
    use Mojolicious::Plugin::Buffer::Lock::Redis;

    my $lock = Mojolicious::Plugin::Buffer::Lock::Redis->new(
        redis => sub {
            Redis->new(
                server       => 'redis://127.0.0.1:6379',
                read_timeout => 1,
            );
        },
        namespace => 'myapp:buffer:',
        ttl       => 60,
    );

    my ($guard, $error) = $lock->acquire($key);
    ...
    $lock->release($guard);

=head1 DESCRIPTION

A distributed lock backend for L<Mojolicious::Plugin::Buffer/cache_lock>, so
workers on different hosts can elect a single builder for a missing cache
entry.  The cache itself must also be shared between those workers.

Locks are set with C<SET ... NX PX>, which is atomic.  The value is a unique
token per acquisition, and release uses a small Lua script to delete the key
only when it still contains that token.  A lock also expires after
L</ttl> seconds, so a crashed worker cannot block the key for ever.

The Redis client is called synchronously, before the action is allowed to
continue, so it must not use a non-blocking API.  Set connect, read and write
timeouts on the client; a slow Redis server delays the request.  Redis 2.6.12
or newer is required for C<SET ... NX PX>.

=head1 ATTRIBUTES

=head2 redis

A Redis client object with the same C<eval($script, $numkeys, @args)> method
as L<Redis> and L<Redis::Fast>, or a code reference that returns one.  The
code reference is called lazily, once per worker, and is the safe choice for
pre-forking servers: a client object created in C<startup> is inherited by
every worker and must not be used.  Required.

=head2 namespace

Prefix for the Redis keys, defaults to C<'buffer:lock:'>.  The rest of the
key is an MD5 digest of the cache key.  Use a different namespace for each
application sharing a Redis database.

=head2 ttl

How long an acquired lock lives, in seconds, defaults to 60.  It should be
longer than L<Mojolicious::Plugin::Buffer/cache_lock_timeout> and longer than
the slowest action that uses the cache.  If it expires while the builder is
still working, another worker can start building the same entry.

=head1 METHODS

=head2 acquire

    my ($guard, $error) = $lock->acquire($key);

Returns a truthy guard when the lock was acquired, C<(undef, undef)> when
another worker holds it, and C<(undef, $error)> when Redis is unavailable.
The plugin logs an error and continues without a cross-worker lock in the
last case.

=head2 release

    $lock->release($guard);

Releases a guard returned by L</acquire>.  Returns C<(1, undef)> on success
and C<(0, $error)> on failure; a failed release is not fatal because the lock
expires after L</ttl>.

=head1 SEE ALSO

L<Mojolicious::Plugin::Buffer>,
L<Mojolicious::Plugin::Buffer::Lock::File>.

=cut
