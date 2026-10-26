package Mojolicious::Plugin::Buffer::Lock::File;

use strict;
use warnings;
use autodie qw(:all);

use Mojo::Base -base;

use Carp qw(croak);
use Fcntl qw(:flock O_CREAT O_RDWR);
use File::Path ();
use File::Spec ();
use Mojo::Util qw(md5_sum trim);
use Mojolicious::Plugin::Buffer::I18N qw(i18n);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Scalar::Util qw(blessed);
use Sub::Private { mode => 'enforce' };
use Sub::Protected;

our $VERSION = '0.001.0';

# Lock files are created world-readable/writable before the umask is applied,
# so the directory's permissions decide who may take a lock
Readonly::Scalar my $LOCK_FILE_MODE => oct('0666');
Readonly::Scalar my $LOCK_FILE_SUFFIX => '.lock';

has dir => undef;
has messages => undef;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Buffer::Lock::File - flock-based lock backend

=head1 VERSION

Version 0.001.0

=head1 SYNOPSIS

    use Mojolicious::Plugin::Buffer::Lock::File;

    my $lock = Mojolicious::Plugin::Buffer::Lock::File->new(
	dir => '/var/lib/myapp/buffer-locks',
    );

    my ($guard, $error) = $lock->acquire($key);
    ...
    $lock->release($guard);

=head1 DESCRIPTION

The built-in lock backend used by
L<Mojolicious::Plugin::Buffer/cache_lock_dir>.  It takes a non-blocking
exclusive C<flock> on one small, empty file per cache key, so a lock is
released automatically if the process dies.  Lock files are not removed, but
they are tiny and can be deleted while the application is stopped.

All workers must share the directory.  Use
L<Mojolicious::Plugin::Buffer::Lock::Redis> instead when the workers are on
different hosts.

=head1 ATTRIBUTES

=head2 dir

The directory holding the lock files.  It is created if necessary and must be
writable.  Required.

=head2 messages

An optional hash of message overrides, see
L<Mojolicious::Plugin::Buffer::I18N>.  The plugin passes its own C<messages>
option here when it builds this backend from C<cache_lock_dir>.

=head1 METHODS

=head2 new

    my $lock = Mojolicious::Plugin::Buffer::Lock::File->new(dir => $dir);

=head3 Purpose

Create the backend, creating the lock directory if necessary.

=head3 Arguments

=over 4

=item C<dir> (named, required)

A directory path, as a non-empty string.

=item C<messages> (named, optional)

A hash of message overrides.

=back

=head3 Returns

The new object.

=head3 Side effects

Creates C<dir> and any missing parents.

=head3 Example

    my $lock = Mojolicious::Plugin::Buffer::Lock::File->new(
	dir => '/var/lib/myapp/buffer-locks',
    );

=head3 API SPECIFICATION

=head4 Input

    {
	dir      => { type => 'string', min => 1 },
	messages => { type => 'hashref', optional => 1 },
    }

=head4 Output

    # Return::Set schema
    { type => 'object', isa => 'Mojolicious::Plugin::Buffer::Lock::File' }

=head3 MESSAGES

    Key                     Message                                         Resolution
    ----------------------  ----------------------------------------------  ---------------------------------
    option_cache_lock_dir   cache_lock_dir must be a directory path         Pass a non-empty string
    lock_dir_create_failed  cannot create cache_lock_dir 'DIR': OS ERROR    Fix the parent's permissions, or
                                                                            the path (e.g. a file is in the
                                                                            way)
    lock_dir_not_writable   cache_lock_dir 'DIR' is not a writable          Change the owner or mode of DIR
                            directory

All three croak.  The OS error is Perl's C<$!> text and follows the
process's C<LC_MESSAGES> only inside C<use locale>.

=head3 FORMAL SPECIFICATION

    [PATH]
    ┌─ New ───────────────────────────────────────
    │ dir? : PATH ; fs, fs′ : PATH ⇸ Node ; result! : FileLock
    ├─────────────────────────────────────────────
    │ dir? ≠ ∅
    │ dir? ∈ dom fs′ ∧ isDirectory(fs′ dir?) ∧ writable(fs′ dir?)
    │ fs ⊆ fs′
    │ result!.dir = dir?
    └─────────────────────────────────────────────
    -- Otherwise: croak, and fs′ may hold the parents created so far

=cut

sub new {
	my ($class, @args) = @_;

	# Params::Get accepts both new(dir => ...) and new({dir => ...})
	my $self = $class->SUPER::new(get_params(undef, @args) // {});
	my $dir = $self->dir;

	croak $self->i18n('option_cache_lock_dir') unless _valid_dir($dir);

	# Ask File::Path for structured errors: plain $! text per path, without
	# the "at FILE line N" its own die would add.  The last entry is about
	# the directory itself, which is the one the user named.
	File::Path::make_path($dir, {error => \my $errors});
	if ($errors && @$errors) {
		my ($path, $message) = %{$errors->[-1]};
		croak $self->i18n('lock_dir_create_failed', {dir => $dir, error => length($path) ? "$path: $message" : $message});
	}
	croak $self->i18n('lock_dir_not_writable', {dir => $dir}) unless -d $dir && -w $dir;

	return $self;
}

=head2 acquire

    my ($guard, $error) = $lock->acquire($key);

=head3 Purpose

Try, without waiting, to become the only process building C<$key>.

=head3 Arguments

=over 4

=item C<$key> (positional, required)

The cache key, any defined string.  Only its MD5 digest reaches the
filesystem.

=back

=head3 Returns

A two-element list, as the lock protocol in
L<Mojolicious::Plugin::Buffer/cache_lock> requires: C<($guard, undef)> when
the lock was taken, C<(undef, undef)> when another process holds it, and
C<(undef, $error)> on failure.  The guard is opaque.

=head3 Side effects

Creates the lock file if it does not exist and keeps it open while the
guard lives.

=head3 Example

    my ($guard, $error) = $lock->acquire('buffer:0123abcd');
    if ($guard) {
	# ... build the entry ...
	$lock->release($guard);
    } elsif (defined $error) {
	warn $error;
    } else {
	# somebody else is building it
    }

=head3 API SPECIFICATION

=head4 Input

    { key => { type => 'string', position => 0 } }

=head4 Output

    # Return::Set schema (list of two)
    {
	type => 'arrayref',
	schema => [
	    { type => 'hashref', optional => 1 },   # guard
	    { type => 'string',  optional => 1 },   # error
	],
    }

=head3 MESSAGES

    Key                 Message                        Resolution
    ------------------  -----------------------------  ---------------------------------
    lock_key_undefined  cache key is not defined       Pass a defined key
    lock_open_failed    cannot open PATH: OS ERROR     Check the directory still exists
                                                       and is writable
    lock_failed         cannot lock PATH: OS ERROR     The filesystem does not support
                                                       flock; use another backend

These are returned, not thrown.

=head3 FORMAL SPECIFICATION

    ┌─ Acquire ───────────────────────────────────
    │ ΔLocks
    │ key? : KEY ; guard! : Guard ∪ {⊥} ; error! : TEXT ∪ {⊥}
    ├─────────────────────────────────────────────
    │ key? ∉ dom held ∧ ok ⇒ held′ = held ⊕ {key? ↦ self}
    │                       ∧ guard! ≠ ⊥ ∧ error! = ⊥
    │ key? ∈ dom held ⇒ held′ = held ∧ guard! = ⊥ ∧ error! = ⊥
    │ ¬ok ⇒ held′ = held ∧ guard! = ⊥ ∧ error! ≠ ⊥
    └─────────────────────────────────────────────

=head3 PSEUDOCODE

    reject an undefined key
    open (creating) DIR/md5(key).lock
    on failure return the OS error
    try a non-blocking exclusive flock
    if it succeeded, return a guard holding the handle
    close the handle
    if flock said "would block", return (undef, undef)
    otherwise return the OS error

=cut

sub acquire {
	my ($self, @args) = @_;

	# get_params() confesses on an empty list; no key is a returned error
	my $key = @args ? get_params('key', @args)->{key} : undef;
	return (undef, $self->i18n('lock_key_undefined')) unless defined($key);

	my $path = $self->_path($key);

	# autodie turns a failed sysopen into an exception carrying $!
	my $fh = eval { sysopen(my $handle, $path, O_RDWR | O_CREAT, $LOCK_FILE_MODE); $handle };
	return (undef, $self->i18n('lock_open_failed', {path => $path, error => _os_error($@)})) unless $fh;

	# autodie does not throw when a LOCK_NB flock would block: it returns
	# false, which is the "somebody else holds it" answer
	my $locked = eval { flock($fh, LOCK_EX | LOCK_NB) };
	my $error = $@;
	return ({fh => $fh, path => $path}, undef) if $locked;

	eval { close($fh) };
	return (undef, undef) unless $error;
	return (undef, $self->i18n('lock_failed', {path => $path, error => _os_error($error)}));
}

=head2 release

    my ($ok, $error) = $lock->release($guard);

=head3 Purpose

Give up a lock taken by L</acquire>.

=head3 Arguments

=over 4

=item C<$guard> (positional, required)

A guard returned by L</acquire>.  A false value, or a guard that was already
released, is accepted and ignored.

=back

=head3 Returns

C<(1, undef)> on success, C<(0, $error)> if unlocking or closing failed.  The
lock is gone either way, because the handle is closed.

=head3 Side effects

Unlocks and closes the lock file handle and removes it from the guard.

=head3 Example

    my ($ok, $error) = $lock->release($guard);
    warn $error unless $ok;

=head3 API SPECIFICATION

=head4 Input

    { guard => { type => 'hashref', optional => 1, position => 0 } }

=head4 Output

    # Return::Set schema (list of two)
    {
	type => 'arrayref',
	schema => [
	    { type => 'boolean' },                  # released
	    { type => 'string', optional => 1 },    # error
	],
    }

=head3 MESSAGES

    Key            Message                        Resolution
    -------------  -----------------------------  -------------------------
    unlock_failed  cannot unlock PATH: OS ERROR   Usually harmless: closing
                                                  the handle drops the lock

=head3 FORMAL SPECIFICATION

    ┌─ Release ───────────────────────────────────
    │ ΔLocks
    │ guard? : Guard ∪ {⊥} ; ok! : 𝔹 ; error! : TEXT ∪ {⊥}
    ├─────────────────────────────────────────────
    │ held′ = held ⩥ {self}  restricted to key(guard?)
    │ ok! = true ⇔ error! = ⊥
    └─────────────────────────────────────────────

=cut

sub release {
	my ($self, $guard) = @_;

	my $fh = (ref($guard) eq 'HASH') ? delete($guard->{fh}) : undef;
	my $ok = !$fh || eval { flock($fh, LOCK_UN); close($fh); 1 };

	# The handle is gone either way, so the lock is gone too; only report
	return $ok
		? (1, undef)
		: (0, $self->i18n('unlock_failed', {path => $guard->{path}, error => _os_error($@)}));
}

# Purpose:        Map a cache key to its lock file path.
# Entry criteria: $key is a defined string.
# Exit status:    An absolute or dir-relative path ending in .lock.
# Side effects:   None.  Protected so a subclass can share a directory
#                 layout, e.g. sharding the files into subdirectories.
sub _path :Protected {
	my ($self, $key) = @_;

	return File::Spec->catfile($self->dir, md5_sum($key) . $LOCK_FILE_SUFFIX);
}

# Purpose:        Check that a value can name the lock directory.
# Entry criteria: Any scalar.
# Exit status:    True for a non-empty, non-reference string.
# Side effects:   None.
sub _valid_dir :Private {
	my $dir = shift;

	return eval { validate_strict(schema => {dir => {type => 'string', min => 1}}, input => {dir => $dir}); 1 } && !ref($dir);
}

# Purpose:        Extract the OS error text from an exception.
# Entry criteria: An autodie::exception, or any other exception.
# Exit status:    The $! text for an autodie exception, else the trimmed
#                 exception text.
# Side effects:   None.
sub _os_error :Private {
	my $exception = shift;

	return (blessed($exception) && $exception->isa('autodie::exception'))
		? '' . $exception->errno
		: trim("$exception");
}

1;

=head1 LIMITATIONS

=over 4

=item * Lock files are never deleted.  Removing one while another process
has it open would let a third process lock a new file of the same name, and
two builders would run.  They are empty, so the cost is one inode per key
ever built.

=item * C<flock> is only advisory and is unreliable on some network
filesystems (older NFS in particular).  Use the Redis backend there.

=item * The protocol returns a two-element list rather than a reference,
because that is the documented interface third-party backends implement.

=back

=head1 SEE ALSO

L<Mojolicious::Plugin::Buffer>, L<Mojolicious::Plugin::Buffer::Lock::Redis>,
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
