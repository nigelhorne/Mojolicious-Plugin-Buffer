package Mojolicious::Plugin::Buffer::Lock::Redis;

use strict;
use warnings;
use autodie qw(:all);

use Mojo::Base -base;

use Carp qw(croak);
use Mojo::Util qw(md5_sum trim);
use Mojolicious::Plugin::Buffer::I18N qw(i18n);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Scalar::Util qw(blessed refaddr);
use Sub::Private { mode => 'enforce' };
use Sub::Protected;
use Time::HiRes ();

our $VERSION = '0.001.0';

Readonly::Scalar my $DEFAULT_NAMESPACE => 'buffer:lock:';
Readonly::Scalar my $DEFAULT_TTL => 60;

# Redis takes PX in milliseconds; a TTL that rounds below 1ms would be
# rejected by the server, so it is clamped to this
Readonly::Scalar my $MS_PER_SECOND => 1000;
Readonly::Scalar my $MIN_TTL_MS => 1;

# Constructor arguments.  The client is checked separately, because CPAN Redis
# dispatches commands through AUTOLOAD and has no eval() for can() to find.
Readonly::Hash my %NEW_SCHEMA => (
	namespace => {type => 'string', min => 1},
	ttl => {type => 'number', matches => qr/^\d+(?:\.\d+)?$/, callback => sub { $_[0] > 0 }},
);

has redis     => undef;
has namespace => $DEFAULT_NAMESPACE;
has ttl       => $DEFAULT_TTL;
has messages  => undef;

# Makes each token unique within a process even within one clock tick
my $TOKEN_COUNTER = 0;

# SET NX PX is atomic, so only one worker can create the key.  The token lets
# the owner release exactly its own lock.
Readonly::Scalar my $ACQUIRE_SCRIPT => <<'LUA';
if redis.call('set', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then
    return 1
end
return 0
LUA

# Compare and delete in one script, so a lock that expired and was taken by
# another worker is never removed by the previous owner.
Readonly::Scalar my $RELEASE_SCRIPT => <<'LUA';
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
end
return 0
LUA

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Buffer::Lock::Redis - Redis-backed lock backend

=head1 VERSION

Version 0.001.0

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

=head2 messages

An optional hash of message overrides, see
L<Mojolicious::Plugin::Buffer::I18N>.

=head1 METHODS

=head2 new

    my $lock = Mojolicious::Plugin::Buffer::Lock::Redis->new(redis => sub { Redis->new });

=head3 Purpose

Create the backend and check its configuration.  No connection is made.

=head3 Arguments

=over 4

=item C<redis> (named, required)

A client object or a code reference returning one.

=item C<namespace> (named, optional)

A non-empty string, default C<'buffer:lock:'>.

=item C<ttl> (named, optional)

A positive number of seconds, default 60.

=item C<messages> (named, optional)

A hash of message overrides.

=back

=head3 Returns

The new object.

=head3 Side effects

None.

=head3 Example

    my $lock = Mojolicious::Plugin::Buffer::Lock::Redis->new(
	redis     => sub { Redis->new(server => 'redis.internal:6379') },
	namespace => 'shop:buffer:',
	ttl       => 30,
    );

=head3 API SPECIFICATION

=head4 Input

    {
	redis     => { type => ['coderef', 'object'] },   # object: eval() or AUTOLOAD
	namespace => { type => 'string', min => 1, optional => 1 },
	ttl       => { type => 'number', min => 0, optional => 1,
	               matches => qr/^\d+(?:\.\d+)?$/ },   # and > 0
	messages  => { type => 'hashref', optional => 1 },
    }

=head4 Output

    # Return::Set schema
    { type => 'object', isa => 'Mojolicious::Plugin::Buffer::Lock::Redis' }

=head3 MESSAGES

    Key                      Message                                   Resolution
    -----------------------  ----------------------------------------  -------------------------------
    redis_client_invalid     cache_lock redis must be an object with   Pass a Redis/Redis::Fast object
                             an eval() method or a code reference      or, better, a factory sub
                             returning one
    redis_namespace_invalid  cache_lock namespace must be a non-empty  Pass e.g. 'myapp:buffer:'
                             string
    redis_ttl_invalid        cache_lock ttl must be a positive number  Pass e.g. 60
                             of seconds

All three croak.

=head3 FORMAL SPECIFICATION

    ┌─ NewRedisLock ──────────────────────────────
    │ redis? : Client ∪ (seq₀ ARG → Client)
    │ namespace? : seq₁ CHAR ; ttl? : ℝ
    │ result! : RedisLock
    ├─────────────────────────────────────────────
    │ ttl? > 0
    │ result!.namespace = namespace? ∧ result!.ttl = ttl?
    └─────────────────────────────────────────────

=cut

sub new {
	my ($class, @args) = @_;

	my $self = $class->SUPER::new(get_params(undef, @args) // {});

	croak $self->i18n('redis_client_invalid') unless _valid_client($self->redis);
	croak $self->i18n('redis_namespace_invalid') unless _valid($self, 'namespace');
	croak $self->i18n('redis_ttl_invalid') unless _valid($self, 'ttl');

	return $self;
}

=head2 acquire

    my ($guard, $error) = $lock->acquire($key);

=head3 Purpose

Try, without waiting, to become the only worker building C<$key>.

=head3 Arguments

=over 4

=item C<$key> (positional, required)

The cache key, any defined string.

=back

=head3 Returns

C<($guard, undef)> when the lock was acquired, C<(undef, undef)> when
another worker holds it, and C<(undef, $error)> when Redis is unavailable.
The plugin logs an error and continues without a cross-worker lock in the
last case.

=head3 Side effects

Connects to Redis on first use (through the factory) and sets a key that
expires after L</ttl>.

=head3 Example

    my ($guard, $error) = $lock->acquire('buffer:0123abcd');
    $lock->release($guard) if $guard;

=head3 API SPECIFICATION

=head4 Input

    { key => { type => 'string', position => 0 } }

=head4 Output

    # Return::Set schema (list of two)
    {
	type => 'arrayref',
	schema => [
	    { type => 'hashref', optional => 1 },   # guard: {key, token}
	    { type => 'string',  optional => 1 },   # error
	],
    }

=head3 MESSAGES

    Key                 Message                                   Resolution
    ------------------  ----------------------------------------  ---------------------------
    lock_key_undefined  cache key is not defined                  Pass a defined key
    redis_lock_failed   Redis lock failed: ERROR                  Check the server and client
    redis_no_client     Redis client factory returned no client   Make the factory return one
    redis_no_result     Redis lock command returned no result     Check the client library

These are returned, not thrown.

=head3 FORMAL SPECIFICATION

    ┌─ AcquireRedis ──────────────────────────────
    │ ΔRedis
    │ key? : KEY ; guard! : Guard ∪ {⊥} ; error! : TEXT ∪ {⊥}
    ├─────────────────────────────────────────────
    │ let k == namespace ⁀ md5(key?) •
    │   k ∉ dom store ∧ reachable ⇒
    │       store′ = store ⊕ {k ↦ token} ∧ expiry′ k = now + ttl
    │       ∧ guard! = (k, token) ∧ error! = ⊥
    │   k ∈ dom store ⇒ store′ = store ∧ guard! = ⊥ ∧ error! = ⊥
    │   ¬reachable ⇒ store′ = store ∧ guard! = ⊥ ∧ error! ≠ ⊥
    └─────────────────────────────────────────────

=head3 PSEUDOCODE

    reject an undefined key
    derive the Redis key and a fresh token
    convert the TTL to milliseconds, at least 1
    run SET NX PX through the Lua script
    if the call failed, return the error
    if it returned nothing, return "no result"
    if it returned 1, return the guard
    otherwise return (undef, undef): someone else holds it

=cut

sub acquire {
	my ($self, @args) = @_;

	# get_params() confesses on an empty list; no key is a returned error
	my $key = @args ? get_params('key', @args)->{key} : undef;
	return (undef, $self->i18n('lock_key_undefined')) unless defined($key);

	my $lock_key = $self->_key($key);
	my $token = $self->_token;
	my $ttl = int($self->ttl * $MS_PER_SECOND);
	$ttl = $MIN_TTL_MS if $ttl < $MIN_TTL_MS;

	my $outcome = $self->_run_script($ACQUIRE_SCRIPT, $lock_key, $token, $ttl);
	return (undef, $self->i18n('redis_lock_failed', {error => $outcome->{error}})) if defined($outcome->{error});
	return (undef, $self->i18n('redis_no_result')) unless defined($outcome->{result});

	return $outcome->{result} ? ({key => $lock_key, token => $token}, undef) : (undef, undef);
}

=head2 release

    my ($ok, $error) = $lock->release($guard);

=head3 Purpose

Delete the lock, but only if it still holds this guard's token.

=head3 Arguments

=over 4

=item C<$guard> (positional, required)

A guard returned by L</acquire>.

=back

=head3 Returns

C<(1, undef)> on success, including when the lock had already expired, and
C<(0, $error)> on failure.  A failed release is not fatal because the lock
expires after L</ttl>.

=head3 Side effects

Deletes the Redis key if it still holds the token.

=head3 Example

    my ($ok, $error) = $lock->release($guard);
    warn $error unless $ok;

=head3 API SPECIFICATION

=head4 Input

    { guard => { type => 'hashref', position => 0 } }   # {key, token}

=head4 Output

    # Return::Set schema (list of two)
    {
	type => 'arrayref',
	schema => [
	    { type => 'boolean' },
	    { type => 'string', optional => 1 },
	],
    }

=head3 MESSAGES

    Key                  Message                       Resolution
    -------------------  ----------------------------  ------------------------------
    redis_invalid_guard  invalid lock guard            Pass the guard acquire returned
    redis_unlock_failed  Redis unlock failed: ERROR    None needed; the TTL expires it

=head3 FORMAL SPECIFICATION

    ┌─ ReleaseRedis ──────────────────────────────
    │ ΔRedis
    │ guard? : Guard ; ok! : 𝔹
    ├─────────────────────────────────────────────
    │ store guard?.key = guard?.token ⇒ store′ = {guard?.key} ⩤ store
    │ store guard?.key ≠ guard?.token ⇒ store′ = store
    └─────────────────────────────────────────────

=cut

sub release {
	my ($self, $guard) = @_;

	my $valid = (ref($guard) eq 'HASH') && defined($guard->{key}) && defined($guard->{token});
	my $outcome = $valid ? $self->_run_script($RELEASE_SCRIPT, $guard->{key}, $guard->{token}) : {};

	# An expired lock (script result 0) is still a successful release
	return !$valid ? (0, $self->i18n('redis_invalid_guard'))
		: defined($outcome->{error}) ? (0, $self->i18n('redis_unlock_failed', {error => $outcome->{error}}))
		: (1, undef);
}

# Purpose:        Run one of the Lua scripts against a single key.
# Entry criteria: $script is Lua; $key and @argv are strings.
# Exit status:    {result => $value} on success, {error => $text} when the
#                 factory returned nothing or the client died.
# Side effects:   Network round trip; may create the per-worker client.
sub _run_script :Private {
	my ($self, $script, $key, @argv) = @_;

	my $redis = eval { $self->_client };
	my $error = $@;
	$error = $self->i18n('redis_no_client') if !$error && !$redis;

	my $result = $error ? undef : eval { $redis->eval($script, 1, $key, @argv) };
	$error ||= $@;

	return $error ? {error => trim("$error")} : {result => $result};
}

# Purpose:        Return the Redis client, calling the factory once.
# Entry criteria: redis is an object or a code reference.
# Exit status:    The client, or whatever the factory returned.
# Side effects:   Caches the factory result for this object; may die if
#                 the factory dies.  Protected so a subclass can supply a
#                 pooled or sentinel-aware client.
sub _client :Protected {
	my $self = shift;

	my $redis = $self->redis;

	# Called lazily, so a pre-forking server gets one connection per worker
	return ref($redis) eq 'CODE' ? ($self->{client} //= $redis->()) : $redis;
}

# Purpose:        Map a cache key to its Redis key.
# Entry criteria: $key is a defined string.
# Exit status:    namespace followed by the MD5 of the key.
# Side effects:   None.  Protected so a subclass can add e.g. a hash tag
#                 for Redis Cluster slot placement.
sub _key :Protected {
	my ($self, $key) = @_;

	return $self->namespace . md5_sum($key);
}

# Purpose:        Produce a token that no other acquisition will share.
# Entry criteria: None.
# Exit status:    A 32-character hex string.
# Side effects:   Increments the per-process counter.
sub _token :Protected {
	my $self = shift;

	return md5_sum(join "\0", $$, Time::HiRes::time(), ++$TOKEN_COUNTER, rand(), refaddr($self));
}

# Purpose:        Check a client value without connecting.
# Entry criteria: Any scalar.
# Exit status:    True for a code reference, or an object with eval() or an
#                 AUTOLOAD that will provide it.
# Side effects:   None.
sub _valid_client :Private {
	my $redis = shift;

	return (ref($redis) eq 'CODE')
		|| (blessed($redis) && ($redis->can('eval') || $redis->can('AUTOLOAD')));
}

# Purpose:        Validate one attribute against %NEW_SCHEMA.
# Entry criteria: $self is constructed; $name is a key of %NEW_SCHEMA.
# Exit status:    True if the attribute's value is acceptable.
# Side effects:   None.
sub _valid :Private {
	my ($self, $name) = @_;

	my $value = $self->$name;
	return !ref($value) && eval { validate_strict(schema => {$name => $NEW_SCHEMA{$name}}, input => {$name => $value}); 1 };
}

1;

=head1 LIMITATIONS

=over 4

=item * The client is called synchronously inside a request.  A slow or
partitioned Redis server stalls that worker for as long as the client's own
timeouts allow; there is no circuit breaker.

=item * This is a single-instance lock, not Redlock.  With Redis replication,
a fail-over can lose a lock that was just set, and two builders may run.  For
a cache that is acceptable: the cost is one duplicated build, not corrupted
data.

=item * A lock that outlives L</ttl> is silently lost, and a second builder
can start.  Choose a TTL longer than the slowest cached action.

=back

=head1 SEE ALSO

L<Mojolicious::Plugin::Buffer>,
L<Mojolicious::Plugin::Buffer::Lock::File>,
L<Mojolicious::Plugin::Buffer::I18N>.

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option)
any later version.

=cut
