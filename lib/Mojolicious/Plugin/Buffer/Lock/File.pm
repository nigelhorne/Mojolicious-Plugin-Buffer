package Mojolicious::Plugin::Buffer::Lock::File;

use Mojo::Base -base;

use Carp qw(croak);
use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(:flock O_CREAT O_RDWR);
use File::Path ();
use Mojo::Util qw(md5_sum);

has dir => undef;

sub new {
	my ($class, @args) = @_;

	my $self = $class->SUPER::new(@args);
	my $dir = $self->dir;
	croak 'Mojolicious::Plugin::Buffer: cache_lock_dir must be a directory path'
		if !defined($dir) || ref($dir) || !length($dir);

	eval { File::Path::make_path($dir) };
	croak "Mojolicious::Plugin::Buffer: cannot create cache_lock_dir '$dir': $@" if $@;
	croak "Mojolicious::Plugin::Buffer: cache_lock_dir '$dir' is not a writable directory"
		unless -d $dir && -w $dir;

	return $self;
}

# Take a non-blocking flock on a file named after the cache key.  Returns a
# guard on success, (undef, undef) when another process holds it, and
# (undef, error) for anything else.
sub acquire {
	my ($self, $key) = @_;

	my $path = $self->dir . '/' . md5_sum($key) . '.lock';
	my $fh;
	unless (sysopen($fh, $path, O_RDWR | O_CREAT, 0666)) {
		return (undef, "cannot open $path: $!");
	}

	if (flock($fh, LOCK_EX | LOCK_NB)) {
		return ({fh => $fh, path => $path}, undef);
	}

	my $error = "$!";
	my $errno = 0 + $!;
	close($fh);

	return (undef, undef) if ($errno == EWOULDBLOCK) || ($errno == EAGAIN);
	return (undef, "cannot lock $path: $error");
}

sub release {
	my ($self, $guard) = @_;

	return (1, undef) unless $guard && $guard->{fh};
	flock($guard->{fh}, LOCK_UN);
	close(delete $guard->{fh});

	return (1, undef);
}

1;

=head1 NAME

Mojolicious::Plugin::Buffer::Lock::File - flock-based lock backend

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

=head1 METHODS

=head2 acquire

    my ($guard, $error) = $lock->acquire($key);

Returns a truthy guard when the lock was acquired, C<(undef, undef)> when
another process holds it, and C<(undef, $error)> on failure.  The guard is
opaque to the caller.

=head2 release

    $lock->release($guard);

Releases a guard returned by L</acquire>.  Returns C<(1, undef)> on success.

=head1 SEE ALSO

L<Mojolicious::Plugin::Buffer>, L<Mojolicious::Plugin::Buffer::Lock::Redis>.

=cut
