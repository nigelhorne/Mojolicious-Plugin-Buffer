package Mojolicious::Plugin::Buffer;

use Mojo::Base 'Mojolicious::Plugin';

use Carp qw(croak);
use Encode ();
use File::Spec ();
use Mojo::Date;
use Mojo::IOLoop;
use Mojo::Util qw(gzip md5_sum);
use Mojolicious::Plugin::Buffer::Lock::File;
use Scalar::Util qw(blessed refaddr);
use Time::HiRes ();

use version; our $VERSION = version->declare('0.001.0');

# Server preference order for content codings
my @DEFAULT_ENCODINGS = qw(br zstd gzip);

# Media types worth compressing
my @DEFAULT_COMPRESSIBLE_TYPES = (
	qr{^text/},
	qr{^application/(?:ecmascript|javascript|json|ld\+json|xhtml\+xml|xml)$},
	qr{^image/svg\+xml$},
);

# Types that must never be buffered and compressed, even though they
# match one of the rules above
my @DEFAULT_EXCLUDED_TYPES = (
	qr{^text/event-stream$},
);

my %DEFAULTS = (
	compress_content   => 1,	# compress responses with gzip/br/zstd
	optimise_content   => 0,	# 1 = squash HTML, 2 = also be aggressive with JavaScript
	rewrite_links      => 1,	# make same-site absolute links relative
	generate_etag      => 1,
	generate_304       => 1,
	trust_last_modified => 0,	# also answer If-Modified-Since when an ETag exists
	last_modified      => 1,	# 0 = off, 1 = newest app/template mtime, epoch, date string or coderef
	template_mtime_cache => undef,	# cache object for the template mtime scan
	template_mtime_cache_duration => 10,	# seconds to keep a cached template mtime
	min_compress_size  => 32,
	encodings          => [@DEFAULT_ENCODINGS],
	compressible_types => [@DEFAULT_COMPRESSIBLE_TYPES],
	excluded_types     => [@DEFAULT_EXCLUDED_TYPES],
	cache              => undef,	# a CHI-like cache object
	cache_duration     => '10 minutes',
	cache_key          => undef,	# string or coderef, overriding the generated key
	cache_single_flight => 1,	# let one request build a missing entry, others wait
	cache_lock_timeout => 10,	# seconds before waiters give up
	cache_lock         => undef,	# pluggable lock backend object
	cache_lock_dir     => undef,	# directory of shared lock files, for multiple workers
	vary_by            => ['cookie'],	# request headers that become part of the cache key
);

my %KNOWN_OPTION = map { $_ => 1 } keys %DEFAULTS;

=head1 NAME

Mojolicious::Plugin::Buffer - Optimise, compress and validate Mojolicious responses

=head1 VERSION

Version 0.001.0

=cut

=head1 SYNOPSIS

    # Mojolicious::Lite
    use Mojolicious::Lite;

    plugin 'Buffer' => {
	optimise_content => 1,
	compress_content => 1,
    };

    get '/' => sub {
	my $c = shift;
	$c->render(template => 'index');
    };

    app->start;

The same plugin in a full Mojolicious application:

    package MyApp;
    use Mojo::Base 'Mojolicious';

    sub startup {
	my $self = shift;
	$self->plugin('Buffer', optimise_content => 1);
	$self->routes->get('/' => sub {
	    my $c = shift;
	    $c->render(template => 'index');
	});
    }

Compression is negotiated from the C<Accept-Encoding> request header, so
nothing extra is needed in your actions - a client that accepts gzip gets
gzip, everyone else gets the uncompressed response.

A server-side cache is optional and opt-in per action.  Give the plugin any
object that understands C<get()>, C<set()> and C<remove()>, such as L<CHI>,
and call the helper before doing any work:

    use CHI;
    plugin 'Buffer' => {cache => CHI->new(driver => 'File')};

    get '/expensive' => sub {
	my $c = shift;
	return if $c->buffer_is_cached;   # the cached response has been sent
	# ... do the expensive work ...
	$c->render(template => 'expensive');
    };

To turn the plugin off, or to override its options, for a single response,
put a C<buffer> value in the stash:

    # Don't touch this response at all (e.g. it is already compressed,
    # or the user is downloading it)
    $c->stash(buffer => 0);

    # Use different options for this response
    $c->stash(buffer => {compress_content => 0, optimise_content => 0});

=head1 DESCRIPTION

C<Mojolicious::Plugin::Buffer> is the Mojolicious equivalent of
L<CGI::Buffer> and L<FCGI::Buffer>.  It buffers the response that your
application has produced, then, before it is sent:

=over 4

=item * optimises HTML by removing superfluous white space and comments,
minifying embedded CSS and JavaScript, and replacing links back to your own
site with relative links;

=item * compresses the response with whichever of Brotli, Zstandard or gzip
the client prefers and the server supports;

=item * adds C<ETag>, C<Last-Modified> and C<Vary> headers, and answers
C<If-None-Match> conditional requests, or C<If-Modified-Since> when no
C<ETag> is generated, with C<304 Not Modified>;

=item * sets an accurate C<Content-Length> after the above changes;

=item * optionally stores the finished page in a server-side cache and
replays it for later requests, so that an action can skip its expensive
work entirely (see L</buffer_is_cached>).

=back

Unlike the CGI modules there is no source filter and no C<END> block: a
Mojolicious plugin can see the finished response through a hook, so the same
effect is achieved without buffering C<STDOUT> or guessing the environment.
The plugin hooks C<after_dispatch>, which is emitted once for every
response, after the renderer has put the content into the response and
before the transaction is resumed.  This means it also sees responses
that were built with C<$c-E<gt>res-E<gt>body> rather than C<$c-E<gt>render>.

=head1 OPTIONS

All options can be given to C<plugin()> and, except where noted, overridden
per request through the C<buffer> stash value.

=head2 compress_content

Compress eligible responses, defaults to 1.  Set to 0 to only optimise (and
remember that the plugin turns off L<Mojolicious::Renderer/compress>, so a
response will then not be compressed at all).  The encodings offered to
clients are controlled by L</encodings>.

Like L</optimise_content>, it can be declared once for a group of pages, which
is the point of a section that serves files it has already compressed:

    my $assets = $r->under('/assets')->to(compress_content => 0);

    package MyApp::Controller::Assets;
    use Mojo::Base 'Mojolicious::Controller';
    has buffer_compress_content => 0;

A route default raises or lowers it for that route, the declaration beats the
plugin option, and the C<buffer> stash overrides both.

=head2 optimise_content

How hard to optimise HTML, defaults to 0 (off):

=over 4

=item 0 - leave the HTML alone

=item 1 - remove superfluous white space, rewrite same-site links and, when
L<HTML::Packer> is installed, remove comments and minify embedded CSS

=item 2 - as 1, plus aggressive JavaScript minification when L<HTML::Packer>
is installed, which can break scripts that rely on the
C<E<lt>!-- ... --E<gt>> hiding technique

=back

Optimisation only applies to C<text/html> and C<application/xhtml+xml>
responses.  L<HTML::Packer> is optional: without it the white-space
squashing and link rewriting still run, but comments and embedded CSS and
JavaScript are left alone, as they are by L<CGI::Buffer> and
L<FCGI::Buffer>.  Install L<HTML::Packer> for the full effect.

Like L</trust_last_modified>, it can be declared once for a group of pages,
as a route default, an C<under> route or a controller method:

    $r->get('/about' => {optimise_content => 1} => sub {...});
    my $docs = $r->under('/docs')->to(optimise_content => 1);

    package MyApp::Controller::Docs;
    use Mojo::Base 'Mojolicious::Controller';
    has buffer_optimise_content => 1;

A declaration beats the plugin option, a route default of C<0> turns
optimisation off inside a group that has it on, and the C<buffer> stash
overrides both.

=head2 rewrite_links

When optimising, rewrite C<E<lt>a hrefE<gt>> and C<E<lt>img srcE<gt>> links that
point at the current site as absolute URLs into root-relative links, and
links to the current script with a query string into just the query string.
Defaults to 1.  Has no effect unless L</optimise_content> is enabled.

It is declared for a group of pages in the same way as L</optimise_content>,
which matters for a section whose HTML is not used in place: a preview of a
newsletter or a page rendered for another site needs its absolute URLs kept
while still being optimised elsewhere.

    my $preview = $r->under('/preview')->to(optimise_content => 1, rewrite_links => 0);

=head2 generate_etag

Add an C<ETag> header to C<200> responses to C<GET> and C<HEAD> requests,
defaults to 1.  The tag is the MD5 of the response body before compression,
with a suffix for the content coding, so a gzip and an identity
representation of the same page have different tags.

Unlike L</optimise_content>, this is not declarable for a group of pages: it
is a per-endpoint decision about whether a digest is worth computing, not a
policy for a section of the site.  Skip the digest for one response with
C<< $c->stash(buffer => {generate_etag => 0}) >>, or for the whole
application with the plugin option.

=head2 generate_304

Answer conditional requests with C<304 Not Modified> when the
C<If-None-Match> header matches, defaults to 1.  C<If-None-Match> takes
precedence over C<If-Modified-Since>, as required by RFC 7232.

C<If-Modified-Since> is only used when no C<ETag> is generated for the
response, which means L</generate_etag> is off, unless L</trust_last_modified>
opts back in.  C<Last-Modified> is derived from the application and its
templates, and says nothing about the data a page was rendered from: a
database row or a stash value can change while the template stays untouched.
A 304 on the timestamp alone would tell such a client that its stale copy is
current, so with an C<ETag> available only the tag can revalidate the
response.  Clients that have the tag, which includes browsers after the first
C<200>, send C<If-None-Match> and are unaffected.

Like L</generate_etag>, this is not declarable for a group of pages.  It is
the switch that decides whether a client is told its copy is current, and a
group that also sets L</trust_last_modified> would contradict itself if it
could turn the answer off as well.  Use
C<< $c->stash(buffer => {generate_304 => 0}) >> where one endpoint must always
send a body.

=head2 last_modified

Add a C<Last-Modified> header, and honour C<If-Modified-Since> when no
C<ETag> is generated (see L</generate_304>) or L</trust_last_modified> is
set, defaults to 1, which uses the newest modification time of the
application script (C<$0>) and the renderer's template files and directories.
May be:

=over 4

=item 0 - do not generate the header

=item 1 - use the newest modification time of the application script
(C<$0>) and the files and directories under the renderer's template paths

=item a number - a Unix epoch

=item a date string - anything L<Mojo::Date> can parse

=item a coderef - called with the controller, returns any of the above

=back

The value is ignored for responses that are not C<200> responses to
C<GET> or C<HEAD> requests.  If C<If-None-Match> is present it takes
precedence over C<If-Modified-Since>, as required by RFC 7232.

The default is the newest mtime of the application file and the files and
directories under the renderer's C<paths>, so editing a template changes
C<Last-Modified> and discards cache entries built from the old one.  C<morbo>
and C<hypnotoad> set C<$0> to your application script, but under a PSGI or
module-only deployment it may be the wrapper instead; pass an explicit epoch
or a coderef there.  The template paths are scanned once per request, unless
L</template_mtime_cache> is configured, so for a large tree or an application
that does not use templates, an explicit epoch or coderef is cheaper.
Database rows and other inputs are not covered; use a coderef for pages whose
freshness depends on them, or set C<last_modified =E<gt> 0> and rely on
L</generate_etag> alone.  A page whose data changes without its template
changing is never answered with a 304 from this timestamp while an C<ETag> is
generated, but the header itself still only describes the code, so a client
that keeps C<If-Modified-Since> without the tag will keep refetching it.

=head2 trust_last_modified

Answer C<If-Modified-Since> even when an C<ETag> is generated, defaults to 0.
Only enable it for pages whose body is a function of the application and its
templates, with no database rows, session values or other inputs that can
change under an untouched template.

L</last_modified> describes the code, not the body, which is why
C<If-Modified-Since> is otherwise ignored while a tag exists.  Turning this
on restores timestamp revalidation for clients that send only
C<If-Modified-Since>, so a page rendered from its templates alone can be
revalidated by those clients without a tag.  C<If-None-Match> still takes
precedence, so a client holding the tag is still protected from a stale copy
even here:

    plugin 'Buffer' => {
	trust_last_modified => 1,   # this application only renders templates
    };

Use it per response instead with C<< $c->stash(buffer => {trust_last_modified
=> 1}) >> when only some pages are that predictable.

A whole group of pages can opt in once.  The easiest way is a route default,
which L<Mojolicious> copies into the stash:

    # one route
    $r->get('/about' => {trust_last_modified => 1} => sub {...});

    # everything beneath an under route
    my $docs = $r->under('/docs')->to(trust_last_modified => 1);
    $docs->get('/intro' => sub {...});

A controller can declare it for itself and, through a base class, for its
whole namespace:

    package MyApp::Controller::Docs;
    use Mojo::Base 'Mojolicious::Controller';
    has buffer_trust_last_modified => 1;

    sub intro { shift->render(template => 'docs/intro') }

A plain C<sub buffer_trust_last_modified { 1 }> works too, for a value that
depends on something the controller knows at request time.

A route default wins over the controller declaration, so a route default of
C<0> opts one page back out of a trusting namespace, and the C<buffer> stash
overrides both.  The declaration has no effect when L</generate_304> is off,
and it cannot make a page safe: it only says that the application and its
templates really are the only inputs.  L</optimise_content> can be declared
for a group in the same way.

=head2 Last-Modified performance

The scan costs one C<stat()> per file and directory under the renderer's
paths.  On a tree of 10,000 templates in 100 directories, a request using the
default scan took about 40 milliseconds of CPU on the machine used for these
measurements, against about 1 millisecond for the same request with an
explicit epoch; that is roughly 4 microseconds per tree entry.  With
L</template_mtime_cache> in front of it, the same request also took about 1
millisecond, the cache lookup adding only a few tens of microseconds, so the
middle ground gives up roughly 2% of the scan's cost to keep template
awareness.  The numbers are indicative, not a promise, and a faster or slower
filesystem will move them.  Run F<benchmarks/last_modified.pl> with your own
tree size to measure all three variants.

Use an explicit epoch or a coderef when template changes do not need to move
C<Last-Modified> and you do not rely on response-cache invalidation after a
template edit.  Use L</template_mtime_cache> when you need template awareness
but not a scan on every request: it costs one cache lookup per request and
bounds how long a template edit can be missed by its duration.

=head2 template_mtime_cache

An optional cache object understanding C<get()> and C<set()>, such as a
L<CHI> instance, used to remember the result of the template mtime scan.
Defaults to undef, which scans the renderer's template paths on every
request.  A per-worker cache avoids the scan without sharing anything:

    use CHI;
    plugin 'Buffer' => {
        template_mtime_cache => CHI->new(driver => 'Memory', datastore => {}),
    };

A shared cache, such as CHI's File or Memcached driver, also avoids the scan
for every worker.  Entries are keyed by the application class, the
application script and its mtime, and the renderer's template paths, and are
stored with L</template_mtime_cache_duration>.  A cache failure is logged at
debug level and the scan runs as usual, so a broken cache cannot stop a
response.

For a large tree this is the middle ground: it avoids the per-request scan
described under L</Last-Modified performance> while still noticing template
changes, at the cost of up to one duration of staleness.

The cached value is only refreshed when the entry expires.  A template edit
therefore is not noticed until then, and neither C<Last-Modified> nor the
cache invalidation described under L</last_modified> sees it immediately.
Keep L</template_mtime_cache_duration> short if templates change often.

This option and L</template_mtime_cache_duration> are read when the plugin is
registered; they cannot be overridden through the C<buffer> stash.

=head2 template_mtime_cache_duration

How long a template mtime is kept, defaults to 10 seconds.  It is passed to
the cache's C<set()>, so for L<CHI> it may be a number of seconds or a
human-readable duration.

=head2 min_compress_size

Do not compress bodies smaller than this many bytes, defaults to 32.
Compression is also skipped if it would not make the body smaller.

=head2 encodings

An arrayref of the content codings to offer, in server preference order.
Defaults to C<[qw(br zstd gzip)]>.  C<br> is only offered if
L<IO::Compress::Brotli> is installed and C<zstd> only if L<Compress::Zstd>
is installed; gzip is always available.  Clients pick with the usual
quality values, and C<identity> is used when nothing acceptable is offered.

=head2 compressible_types

An arrayref of media types to compress, defaults to C<text/*>,
C<application/json>, C<application/javascript>, C<application/xml>,
C<application/xhtml+xml>, C<image/svg+xml> and a few close relatives.
Entries may be strings (matched exactly, case-insensitively) or regular
expressions.

=head2 excluded_types

An arrayref of media types that are never buffered, defaults to
C<text/event-stream>.  Entries may be strings or regular expressions.

=head2 cache

An optional cache object understanding C<get()>, C<set()> and C<remove()>,
such as a L<CHI> instance.  Defaults to undef, which disables the
server-side cache.  See L</buffer_is_cached> for the rules about what is
cached and how keys are made.

=head2 cache_duration

How long entries are kept in the cache, defaults to C<'10 minutes'>.  It is
passed to the cache's C<set()>, so for L<CHI> it may be a number of seconds
or a human-readable duration.

=head2 cache_key

A string, or a coderef called with the controller, that overrides the
generated cache key.  Useful when several URLs should share one entry, or
when the response depends on something the default key does not cover.

=head2 cache_single_flight

Only let one request at a time build a missing entry, defaults to 1.  When a
request misses the cache while another request in the same worker is already
building the same key, the second request waits for the first one to finish
and is then served the finished entry, without running the action.  This
matters for asynchronous actions: a synchronous action runs to completion
without the event loop doing anything else, so it cannot overlap with
another request in the same worker.

If the first request fails, produces a response that cannot be cached (for
example one that sets a cookie), or takes longer than L</cache_lock_timeout>,
the waiting request is answered with C<503 Service Unavailable> and
C<Retry-After: 1> rather than running the action itself.  Set to 0 to let
every concurrent miss run the action independently.

By default the in-flight table is per worker process, so with N L<hypnotoad>
workers a cold entry can still be built up to N times.  Set L</cache_lock> or
L</cache_lock_dir> to elect a single builder across processes instead.

=head2 cache_lock

An optional object that elects one process to build a missing entry, for
workers that cannot share a directory.  It must implement:

=over 4

=item acquire

    my ($guard, $error) = $lock->acquire($key);

Return a truthy guard if the lock was acquired, C<(undef, undef)> if another
process holds it, and C<(undef, $error)> if the backend failed.  On an error
the plugin logs the message and continues with a per-worker flight, so a
cache miss is still built.

The call is synchronous and runs before the action is allowed to continue.
A backend must therefore be quick and must not depend on the event loop; an
asynchronous Redis client is not suitable.

=item release

    $lock->release($guard);

Release a guard returned by C<acquire>.  The guard is opaque to the plugin.
Releasing a lock that has already expired is allowed.  If release fails, the
lock should expire on its own; the backend can return C<(0, $error)> so the
failure is logged.

=back

The cache itself must still be shared between the workers.  The built-in
backends are L<Mojolicious::Plugin::Buffer::Lock::File>, selected with
L</cache_lock_dir>, and L<Mojolicious::Plugin::Buffer::Lock::Redis>.
C<cache_lock> cannot be combined with L</cache_lock_dir>, and is read when
the plugin is registered rather than per response.

=head2 cache_lock_timeout

How long a request may wait for another request, in this worker or another
one, to build the same entry.  Defaults to 10 seconds.  It also bounds how
long a key is considered to be in flight when the request building it never
finishes.  Fractional seconds are allowed, so C<0.5> is valid.

=head2 cache_lock_dir

A directory in which to keep lock files used to coalesce cache misses across
worker processes, defaults to undef, which limits single-flight to one worker.
This selects the built-in L<Mojolicious::Plugin::Buffer::Lock::File> backend
and is a shorthand for C<cache_lock =E<gt>
Mojolicious::Plugin::Buffer::Lock::File-E<gt>new(dir =E<gt> $dir)>.  The
plugin creates the directory if necessary.  It cannot be combined with
L</cache_lock>.

The workers must share this directory and the cache itself.  A per-worker
cache such as CHI's C<Memory> driver cannot be used, because a request in one
worker cannot see the entry built in another; disable any per-worker C<L1>
cache in front of a shared cache for the same reason.  Locks are non-blocking
C<flock>s on one small, empty file per cache key, so they are released
automatically if a worker dies.  The files are not removed, although they are
tiny and can be deleted while the application is stopped.  Use a private
directory.

This works for L<hypnotoad> workers on the same host, or on a shared
filesystem that implements C<flock> reliably.  For workers on different
hosts, use L</cache_lock> with
L<Mojolicious::Plugin::Buffer::Lock::Redis> instead.  It is read when the
plugin is registered, not per response.

=head2 vary_by

An arrayref of request header names that become part of the generated cache
key.  Defaults to C<['cookie']>, which keeps one client's session from being
served to another.  Set it to C<[]> for URL-only caching of pages that are
identical for every visitor, or add e.g. C<'accept-language'> when the
response varies by language.  Headers listed here may also appear in the
response's C<Vary> header; a response that varies on anything else is not
stored.

=head1 METHODS

C<Mojolicious::Plugin::Buffer> inherits all methods from
L<Mojolicious::Plugin> and implements the following new one.  It also adds
the L</buffer_is_cached> helper to the application.

=head2 register

    $plugin->register(Mojolicious->new, {optimise_content => 1});Register the plugin, usually through C<$app-E<gt>plugin('Buffer', ...)>.
Croaks if an unknown option is given or an option has the wrong shape.

=head2 buffer_is_cached

    get '/expensive' => sub {
	my $c = shift;
	return if $c->buffer_is_cached;
	# ... expensive work ...
	$c->render(template => 'expensive');
    };

Look for a cached response and, if there is one, replay its status, headers
and body, add C<X-Cache: HIT>, finish the response and return true.  The
action only has to return; no rendering is needed on a hit.  On a miss it
adds C<X-Cache: MISS>, returns false, and the response is stored when it is
complete.

Only C<200> responses to C<GET> and C<HEAD> requests are cached.  Requests
with an C<Authorization> header or a C<Cache-Control> header containing
C<no-store>, C<no-cache>, C<private> or C<max-age=0> bypass the cache, as do
requests made while the C<NO_CACHE> or C<NO_STORE> environment variable is
set.  Responses that set a cookie, that are marked C<no-store> or
C<private>, or that vary on something not listed in L</vary_by>, are not
stored.  Entries created before the application script or any template file
or directory was last modified are treated as misses and removed.

The stored body is the optimised but uncompressed entity, so every hit is
compressed for the requesting client, gets its own C<ETag> and can still be
answered with C<304 Not Modified>.  The cache key is a digest of the
application class, host, path, query string and the values of the headers
listed in L</vary_by>; use L</cache_key> to replace it.  Query argument order
is significant.

Concurrent misses for the same key are coalesced within a worker, or across
workers when L</cache_lock> or L</cache_lock_dir> is set: while one request
is building an entry, later requests wait for it and replay the result
instead of running the action again.  The waiting requests are held asynchronously, so this
works for actions that themselves use the event loop.  See
L</cache_single_flight> for the failure and timeout behaviour.

Calling the helper more than once is harmless, but only the first call can
hit.  To disable the cache for one response, use
C<< $c->stash(buffer => {cache => undef}) >> before calling it.

=cut

sub register {
	my ($self, $app, $conf) = @_;
	$conf ||= {};

	my %options = %DEFAULTS;
	for my $key (keys %$conf) {
		croak "Mojolicious::Plugin::Buffer: unknown option '$key'" unless $KNOWN_OPTION{$key};
		$options{$key} = $conf->{$key};
	}

	# Validate the shapes up front, rather than in the middle of a request
	croak 'Mojolicious::Plugin::Buffer: encodings must be an array reference'
		unless ref $options{encodings} eq 'ARRAY';
	croak 'Mojolicious::Plugin::Buffer: compressible_types must be an array reference'
		unless ref $options{compressible_types} eq 'ARRAY';
	croak 'Mojolicious::Plugin::Buffer: excluded_types must be an array reference'
		unless ref $options{excluded_types} eq 'ARRAY';
	croak 'Mojolicious::Plugin::Buffer: vary_by must be an array reference'
		unless ref $options{vary_by} eq 'ARRAY';
	for my $name (@{$options{vary_by}}) {
		croak 'Mojolicious::Plugin::Buffer: vary_by entries must be header names'
			unless defined($name) && !ref($name) && length($name);
	}
	if (defined($options{cache_key}) && ref($options{cache_key}) && ref($options{cache_key}) ne 'CODE') {
		croak 'Mojolicious::Plugin::Buffer: cache_key must be a string or a code reference';
	}
	if (defined(my $cache = $options{cache})) {
		croak 'Mojolicious::Plugin::Buffer: cache must be an object understanding get(), set() and remove()'
			unless blessed($cache) && $cache->can('get') && $cache->can('set') && $cache->can('remove');
	}
	if (defined(my $mtime_cache = $options{template_mtime_cache})) {
		croak 'Mojolicious::Plugin::Buffer: template_mtime_cache must be an object understanding get() and set()'
			unless blessed($mtime_cache) && $mtime_cache->can('get') && $mtime_cache->can('set');
	}
	if (defined($options{template_mtime_cache_duration}) &&
	  (ref($options{template_mtime_cache_duration}) || !length($options{template_mtime_cache_duration}))) {
		croak 'Mojolicious::Plugin::Buffer: template_mtime_cache_duration must be a duration';
	}
	if (defined($options{cache_lock_timeout}) &&
	  (ref($options{cache_lock_timeout}) || $options{cache_lock_timeout} !~ /^\d+(?:\.\d+)?$/ || $options{cache_lock_timeout} <= 0)) {
		croak 'Mojolicious::Plugin::Buffer: cache_lock_timeout must be a positive number of seconds';
	}

	# A lock backend makes single-flight work across worker processes.
	# cache_lock_dir is a shorthand for the built-in file backend.
	my $lock;
	if (defined(my $backend = $options{cache_lock})) {
		croak 'Mojolicious::Plugin::Buffer: cache_lock and cache_lock_dir cannot be combined'
			if defined($options{cache_lock_dir});
		croak 'Mojolicious::Plugin::Buffer: cache_lock must be an object with acquire() and release() methods'
			unless blessed($backend) && $backend->can('acquire') && $backend->can('release');
		$lock = $backend;
	}
	elsif (defined(my $dir = $options{cache_lock_dir})) {
		$lock = Mojolicious::Plugin::Buffer::Lock::File->new(dir => $dir);
	}

	# Normalise and check the requested content codings
	my @encodings;
	for my $encoding (@{$options{encodings}}) {
		my $name = lc $encoding;
		$name = 'gzip' if $name eq 'x-gzip';
		croak "Mojolicious::Plugin::Buffer: unknown encoding '$encoding'"
			unless $name =~ /^(?:br|gzip|zstd)$/;
		next if grep { $_ eq $name } @encodings;
		next unless $name eq 'gzip' || _module_available($name);
		push @encodings, $name;
	}
	$options{encodings} = \@encodings;

	# HTML::Packer is optional: without it the white-space squashing and link
	# rewriting still run, as they do in CGI::Buffer and FCGI::Buffer
	if ($options{optimise_content} && !_module_available('HTML::Packer')) {
		$app->log->debug('Buffer: HTML::Packer is not installed, optimising white space only');
	}

	# L<Mojolicious::Renderer> gzips rendered output by default, before this
	# plugin ever sees it, which would stop optimisation and ETag generation
	# from working on anything bigger than 860 bytes.  Take over that job.
	$app->renderer->compress(0);

	my $state = {options => \%options, inflight => {}, lock => $lock};

	$app->hook(after_dispatch => sub {
		my $c = shift;
		return $self->_process($c, $state);
	});

	# Opt-in server-side page cache, used from an action like this:
	#     return if $c->buffer_is_cached;
	$app->helper(buffer_is_cached => sub {
		my $c = shift;
		return $self->_is_cached($c, $state);
	});

	return $self;
}

my %MODULE_CHECK = (
	'br' => sub { eval { require IO::Compress::Brotli; 1 } },
	'zstd' => sub { eval { require Compress::Zstd; 1 } },
	'HTML::Packer' => sub { eval { require HTML::Packer; 1 } },
);

sub _module_available {
	my $name = shift;

	my $check = $MODULE_CHECK{$name}
		or return 0;

	# An ambient $SIG{__DIE__} handler can swallow the die from an @INC hook
	# (Test::Without::Module uses one), which makes a hidden module look
	# loadable.  Probe with the default handler so the load decides.
	local $SIG{__DIE__};

	return $check->() ? 1 : 0;
}

# Options that can be declared for a group of pages, either as a route
# default, which lands in the stash,
#     $r->get('/about' => {trust_last_modified => 1} => sub {...});
#     $r->under('/docs')->to(optimise_content => 1);
# or by the controller itself, which its namespace inherits:
#     sub buffer_optimise_content { 1 }
my @GROUP_OPTIONS = qw(compress_content optimise_content rewrite_links trust_last_modified);

sub _options_for {
	my ($c, $state) = @_;

	my $override = $c->stash->{buffer};
	return (undef, 1) if defined($override) && !ref($override) && !$override;

	my $options = $state->{options};
	$options = {%$options, %$override} if ref($override) eq 'HASH';

	# A route default or a controller class can declare these for a whole
	# group of pages, with the buffer stash still the most specific place to
	# say otherwise
	for my $name (@GROUP_OPTIONS) {
		next if ref($override) eq 'HASH' && exists($override->{$name});
		my $declared = _declared_option($c, $name);
		$options = {%$options, $name => $declared} if defined($declared);
	}

	return ($options, 0);
}

sub _declared_option {
	my ($c, $name) = @_;

	my $stashed = $c->stash->{$name};
	return $stashed if defined($stashed) && !ref($stashed);

	my $method = "buffer_$name";
	return undef unless $c->can($method);

	my $declared = eval { $c->$method };
	if (my $error = $@) {
		# A broken declaration must not take the response down with it; the
		# plugin option stays in force instead
		$error =~ s/\n+\z//;
		$c->app->log->debug("Buffer: $method failed: $error");
		return undef;
	}
	return undef if !defined($declared) || ref($declared);

	return $declared;
}

# Wrap the response pipeline so that a request which was building a cache
# entry always releases the requests waiting for it, whether it succeeded,
# failed, or produced something that must not be cached.
sub _process {
	my ($self, $c, $state) = @_;

	my $flight = $c->stash->{'buffer.flight'};
	my $ok = eval { $self->_process_response($c, $state); 1 };
	my $error = $@;

	if ($flight) {
		my $released = eval {
			_release_flight($c->app, $state, $flight, $c->stash->{'buffer.stored'});
			1;
		};
		$c->app->log->error("Buffer: could not release waiting requests: $@") unless $released;
	}

	die $error unless $ok;
	return;
}

sub _process_response {
	my ($self, $c, $state) = @_;

	my ($options, $disabled) = _options_for($c, $state);
	return if $disabled;

	my $stash = $c->stash;
	my $from_cache = $stash->{'buffer.from_cache'};

	my $res = $c->res;
	my $code = $res->code || 0;
	return if $code && (($code < 200) || ($code == 204) || ($code == 206) || ($code == 304));

	my $headers = $res->headers;

	# Someone else has already encoded the body, e.g. $app->renderer->compress
	return if $headers->content_encoding;

	my $content = $res->content;
	return if $content->is_multipart || $content->is_dynamic;

	# Never slurp files, they are streamed from disk and are not our business
	my $asset = $content->asset;
	return if $asset->is_file;

	my $body = $asset->slurp;
	return unless defined($body) && length($body);

	my $content_type = _mime_type($headers->content_type);
	return unless defined($content_type);
	return if _matches($content_type, $options->{excluded_types});

	my $compressible = _matches($content_type, $options->{compressible_types});

	if (!$from_cache && $options->{optimise_content} &&
	  (($content_type eq 'text/html') || ($content_type eq 'application/xhtml+xml'))) {
		my $optimised = $self->_optimise($body, $c, $options);
		if (defined($optimised) && (length($optimised) < length($body))) {
			$c->app->log->debug('Buffer: optimised HTML from ', length($body), ' to ', length($optimised), ' bytes');
			$body = $optimised;
		}
	}

	# The ETag is calculated from the unencoded entity plus the content coding,
	# so gzip's changing timestamp can never alter it
	my $entity = $body;
	utf8::encode($entity) if utf8::is_utf8($entity);

	my $encoding;
	if ($options->{compress_content} && $compressible) {
		_add_vary($headers);

		my $wanted = _negotiate_encoding($c->req->headers->accept_encoding, $options->{encodings});
		if (defined($wanted) && (length($entity) >= $options->{min_compress_size})) {
			my ($compressed, $error) = _encode_body($wanted, $entity);
			if (defined($compressed)) {
				if (length($compressed) < length($entity)) {
					$encoding = $wanted;
					$body = $compressed;
					$headers->content_encoding($encoding);
					$c->app->log->debug("Buffer: compressed with $encoding from ", length($entity), ' to ', length($compressed), ' bytes');
				}
			} elsif ($error) {
				$c->app->log->error("Buffer: $wanted compression failed: $error");
			}
		}
	}
	$body = $entity unless defined($encoding);

	# Populate the server-side cache with the unencoded entity, so that each
	# client still gets its own content coding and conditional response
	_store_in_cache($c, $options, $entity, $code)
		if !$from_cache && $stash->{'buffer.cache_checked'};

	my $method = $c->req->method;
	my $conditional = ($method eq 'GET') || ($method eq 'HEAD');

	if ($conditional && ($code == 200)) {
		my $last_modified = _resolve_last_modified($options->{last_modified}, $c, $state);
		if (defined($last_modified) && !$headers->last_modified) {
			$headers->last_modified(Mojo::Date->new($last_modified)->to_string);
		}

		my $etag;
		if ($options->{generate_etag}) {
			$etag = $headers->etag;
			if (!defined($etag) || !length($etag)) {
				$etag = '"' . md5_sum($entity . (defined($encoding) ? "\x00$encoding" : '')) . '"';
				$headers->etag($etag);
			}
		}

		if ($options->{generate_304}) {
			my $if_none_match = $c->req->headers->if_none_match;
			my $not_modified;

			if (defined($if_none_match)) {
				# If-None-Match takes precedence; If-Modified-Since is ignored
				# even when there is no ETag to compare it with
				$not_modified = defined($etag) ? _etag_matches($if_none_match, $etag) : 0;
			} elsif ((!defined($etag) || $options->{trust_last_modified}) &&
			  defined($last_modified) &&
			  defined(my $since = $c->req->headers->if_modified_since)) {
				# Without an entity tag, If-Modified-Since is the only validator
				# the client can offer.  Last-Modified comes from the application
				# and its templates, not from the data a page was rendered from,
				# so on its own it cannot show that the representation is
				# unchanged: a database row or a stash value can move under a
				# template that has not been touched.  L</trust_last_modified>
				# is the opt-in for pages where that cannot happen
				my $since_epoch = eval { Mojo::Date->new($since)->epoch };
				$not_modified = 1 if defined($since_epoch) && ($last_modified <= $since_epoch);
			}

			if ($not_modified) {
				$c->app->log->debug('Buffer: not modified, sending 304'
					. (defined($etag) ? " (ETag $etag)" : ''));
				$res->code(304);
				$res->body('');
				$headers->remove('Content-Length');
				return;
			}
		}
	}

	$res->body($body);
	$headers->content_length(utf8::is_utf8($body) ? length(Encode::encode('UTF-8', $body)) : length($body));

	return;
}

# Called by the buffer_is_cached helper.  On a hit the cached response is
# replayed and finished here, so the action only has to return.
sub _is_cached {
	my ($self, $c, $state) = @_;

	my ($options, $disabled) = _options_for($c, $state);
	return 0 if $disabled;

	# Calling the helper more than once should not replay a response twice
	# or register the same request as a waiter again
	return 1 if $c->stash->{'buffer.from_cache'} || $c->stash->{'buffer.cache_waiter'};
	return 0 if $c->stash->{'buffer.flight'};

	my $cache = $options->{cache};
	return 0 unless $cache;
	return 0 unless _request_cacheable($c);

	# From now on a miss should populate the cache at the end of the response
	$c->stash->{'buffer.cache_checked'} = 1;

	my $key = _cache_key($c, $options);
	$c->stash->{'buffer.cache_key'} = $key;

	my ($entry, $error) = _lookup_entry($c, $cache, $key, $state, 1);
	return 0 if $error;
	return _cache_miss($c, $state, $options, $key, $cache) unless $entry;

	$c->app->log->debug("Buffer: cache hit for $key");
	_replay_entry($c, $entry);

	return 1;
}

# Fetch and validate an entry.  Returns (entry, error); the error flag lets
# the initial lookup distinguish a broken cache from a miss, while waiters
# treating either as "not there yet" can ignore it.
sub _lookup_entry {
	my ($c, $cache, $key, $state, $log_errors) = @_;

	my $entry = eval { $cache->get($key) };
	if (my $error = $@) {
		$c->app->log->error("Buffer: cache get failed: $error") if $log_errors;
		return (undef, 1);
	}

	return (undef, 0) unless ref($entry) eq 'HASH' && defined($entry->{body});

	# An entry created before the application was last changed may have been
	# produced by different code, so throw it away
	my $mtime = _application_mtime($c, $state);
	if (defined($mtime) && (($entry->{created} // 0) < $mtime)) {
		$c->app->log->debug('Buffer: discarding a cache entry older than the application or its templates');
		eval { $cache->remove($key) };
		return (undef, 0);
	}

	return ($entry, 0);
}

# A miss either joins an in-flight build for the same key or becomes the
# request that will build and store it.
sub _cache_miss {
	my ($c, $state, $options, $key, $cache) = @_;

	$c->res->headers->header('X-Cache' => 'MISS');
	return 0 unless $options->{cache_single_flight};

	# Include the cache object so that two caches with the same key do not
	# wait for each other
	my $id = refaddr($cache) . "\x00$key";
	if (my $flight = $state->{inflight}{$id}) {
		return _join_flight($c, $state, $flight);
	}

	# With a lock backend, elect one worker to build the entry and make the
	# others wait for it, even though they cannot share the flight table above.
	my $lock;
	if ($state->{lock}) {
		my $error;
		($lock, $error) = _acquire_lock($state->{lock}, $key);
		if (!$lock) {
			if (defined($error)) {
				$c->app->log->error("Buffer: shared cache lock failed: $error");
			} else {
				return _join_shared_lock($c, $state, $options, $key, $cache);
			}
		}
	}

	_start_flight($c, $state, $id, $key, $options, $lock);

	return 0;
}

sub _start_flight {
	my ($c, $state, $id, $key, $options, $lock) = @_;

	my $timeout = _lock_timeout($options);
	my $flight = {
		id => $id,
		key => $key,
		deadline => Time::HiRes::time() + $timeout,
		waiters => {},
		lock => $lock,
	};

	# Do not keep the key reserved for ever if the action never finishes
	$flight->{timer} = Mojo::IOLoop->timer($timeout => sub {
		_expire_flight($c->app, $state, $flight);
	});

	$state->{inflight}{$id} = $flight;
	$c->stash->{'buffer.flight'} = $flight;
	$c->app->log->debug("Buffer: this request will build the cache entry for $key");

	return;
}

# Hold a second request for the same key until the first one has finished.
# The response has to be finished later, so suppress automatic rendering.
sub _join_flight {
	my ($c, $state, $flight) = @_;

	my $id = refaddr($c);
	return 1 if $flight->{waiters}{$id};
	return 1 if $c->stash->{'mojo.finished'};

	$c->stash->{'buffer.cache_waiter'} = 1;
	$c->render_later;

	my $remaining = $flight->{deadline} - Time::HiRes::time();
	$remaining = 0.05 if $remaining < 0.05;
	$flight->{waiters}{$id} = {
		c => $c,
		timer => Mojo::IOLoop->timer($remaining => sub {
			_expire_waiter($c->app, $state, $flight, $id);
		}),
	};

	$c->app->log->debug("Buffer: waiting for the cache entry for $flight->{key}");

	return 1;
}

sub _expire_waiter {
	my ($app, $state, $flight, $id) = @_;

	my $waiter = delete $flight->{waiters}{$id} or return;
	my $c = $waiter->{c};
	return if !$c || $c->stash->{'mojo.finished'};

	$app->log->debug('Buffer: gave up waiting for another request to finish');
	_service_unavailable($c);

	return;
}

# A request in another worker holds the shared lock.  The builder cannot
# notify us, so poll the cache until the entry appears or the lock is gone.
sub _join_shared_lock {
	my ($c, $state, $options, $key, $cache) = @_;

	$c->stash->{'buffer.cache_waiter'} = 1;
	$c->render_later;

	my $deadline = Time::HiRes::time() + _lock_timeout($options);
	$c->app->log->debug("Buffer: waiting for another worker to build the cache entry for $key");

	my ($poll, $done);
	$poll = Mojo::IOLoop->recurring(0.1 => sub {
		return if $done;

		if ($c->stash->{'mojo.finished'}) {
			$done = 1;
			Mojo::IOLoop->remove($poll);
			return;
		}

		my ($entry) = _lookup_entry($c, $cache, $key, $state, 0);
		if ($entry) {
			$done = 1;
			Mojo::IOLoop->remove($poll);
			$c->app->log->debug('Buffer: another worker filled the cache entry');
			_finish_waiting_request($c, $entry);
			return;
		}

		if (Time::HiRes::time() >= $deadline) {
			$done = 1;
			Mojo::IOLoop->remove($poll);
			$c->app->log->debug('Buffer: gave up waiting for another worker');
			_finish_waiting_request($c, undef);
			return;
		}

		# If the lock can be taken, the builder has finished.  Hold it while
		# checking again so that a new builder cannot start in between.
		my ($lock, $error) = _acquire_lock($state->{lock}, $key);
		if (!$lock) {
			return unless defined($error);
			$done = 1;
			Mojo::IOLoop->remove($poll);
			$c->app->log->error("Buffer: shared cache lock failed: $error");
			_finish_waiting_request($c, undef);
			return;
		}

		my ($late) = _lookup_entry($c, $cache, $key, $state, 0);
		my ($released, $release_error) = _release_lock($state->{lock}, $lock);
		$c->app->log->error("Buffer: shared cache unlock failed: $release_error") unless $released;
		$done = 1;
		Mojo::IOLoop->remove($poll);

		if ($late) {
			$c->app->log->debug('Buffer: another worker filled the cache entry');
		} else {
			$c->app->log->debug('Buffer: the other worker did not cache a response');
		}
		_finish_waiting_request($c, $late);
	});

	return 1;
}

sub _finish_waiting_request {
	my ($c, $entry) = @_;

	my $ok = eval {
		if ($entry) {
			_replay_entry($c, $entry);
		} else {
			_service_unavailable($c);
		}
		1;
	};
	$c->app->log->error("Buffer: could not finish a waiting request: $@") unless $ok;

	return;
}

sub _expire_flight {
	my ($app, $state, $flight) = @_;

	my $current = $state->{inflight}{$flight->{id}};
	return unless $current && refaddr($current) == refaddr($flight);

	$app->log->debug('Buffer: an in-flight response did not finish in time');
	_release_flight($app, $state, $flight, undef);

	return;
}

# Finish every request waiting for this key.  With a stored entry they are
# served it; without one (a failed or uncacheable response) they are told to
# retry rather than each running the action, which is what single-flight is
# meant to prevent.
sub _release_flight {
	my ($app, $state, $flight, $entry) = @_;

	my $current = $state->{inflight}{$flight->{id}};
	return unless $current && refaddr($current) == refaddr($flight);

	delete $state->{inflight}{$flight->{id}};
	Mojo::IOLoop->remove($flight->{timer}) if defined($flight->{timer});

	my @waiters = values %{$flight->{waiters}};
	$flight->{waiters} = {};

	for my $waiter (@waiters) {
		Mojo::IOLoop->remove($waiter->{timer}) if defined($waiter->{timer});
		my $c = $waiter->{c};
		next if !$c || $c->stash->{'mojo.finished'};

		my $ok = eval {
			if ($entry) {
				$app->log->debug('Buffer: serving a waiting request from the finished response');
				_replay_entry($c, $entry);
			} else {
				$app->log->debug('Buffer: the in-flight response could not be cached');
				_service_unavailable($c);
			}
			1;
		};
		$app->log->error("Buffer: could not finish a waiting request: $@") unless $ok;
	}

	if (my $lock = delete $flight->{lock}) {
		my ($released, $error) = _release_lock($state->{lock}, $lock);
		$app->log->error("Buffer: shared cache unlock failed: $error") unless $released;
	}

	return;
}

sub _replay_entry {
	my ($c, $entry) = @_;

	$c->res->code($entry->{status} || 200);
	my $headers = $c->res->headers;
	my %seen;
	for my $pair (@{$entry->{headers} || []}) {
		my ($name, $value) = @$pair;
		$headers->remove($name) unless $seen{lc($name)}++;
		$headers->add($name => $value);
	}
	$c->res->body($entry->{body});
	$headers->header('X-Cache' => 'HIT');
	$c->stash->{'buffer.from_cache'} = 1;

	# Finish the response; the action can just return now
	$c->rendered;

	return 1;
}

sub _service_unavailable {
	my $c = shift;

	my $headers = $c->res->headers;
	$c->res->code(503);
	$headers->content_type('text/plain; charset=UTF-8');
	$headers->header('Cache-Control' => 'no-store');
	$headers->header('Retry-After' => 1);
	$headers->header('X-Cache' => 'MISS');
	$c->res->body("The page is being generated, please try again.\n");
	$c->rendered;

	return 1;
}

sub _lock_timeout {
	my $options = shift;

	my $timeout = $options->{cache_lock_timeout};
	return 10 unless defined($timeout) && !ref($timeout) && $timeout =~ /^\d+(?:\.\d+)?$/ && $timeout > 0;

	return $timeout + 0;
}

# Call a pluggable lock backend.  A backend may die, so exceptions are
# converted into errors and the caller can fall back to a per-worker flight
# rather than breaking the request.
sub _acquire_lock {
	my ($backend, $key) = @_;

	my ($guard, $error);
	my $ok = eval { ($guard, $error) = $backend->acquire($key); 1 };
	if (!$ok) {
		my $exception = $@;
		chomp($exception);
		return (undef, $exception);
	}

	return $guard ? ($guard, $error) : (undef, $error);
}

sub _release_lock {
	my ($backend, $lock) = @_;

	return (1, undef) unless $lock;

	my ($ok, $error);
	my $success = eval { ($ok, $error) = $backend->release($lock); 1 };
	if (!$success) {
		my $exception = $@;
		chomp($exception);
		return (0, $exception);
	}

	# A backend that returns nothing is treated as having released the lock
	return (1, undef) unless defined($ok);
	return $ok ? (1, $error) : (0, $error // 'unknown error');
}

sub _store_in_cache {
	my ($c, $options, $entity, $code) = @_;

	my $cache = $options->{cache};
	return unless $cache;
	return unless $code == 200;
	return unless _request_cacheable($c);
	return unless _response_cacheable($c->res, $options);

	my $key = $c->stash->{'buffer.cache_key'} // _cache_key($c, $options);
	my $entry = {
		body => $entity,
		status => 200,
		created => time,
		headers => _headers_to_store($c->res->headers),
	};
	my $duration = defined($options->{cache_duration}) ? $options->{cache_duration} : '10 minutes';

	my $ok = eval { $cache->set($key, $entry, $duration); 1 };
	if (!$ok) {
		$c->app->log->error("Buffer: cache set failed: $@");
		return;
	}

	$c->app->log->debug("Buffer: cached the response for $key");
	$c->res->headers->header('X-Cache' => 'MISS') unless defined($c->res->headers->header('X-Cache'));

	# Hand this entry to any request that was waiting for it
	$c->stash->{'buffer.stored'} = $entry;

	return;
}

sub _cache_key {
	my ($c, $options) = @_;

	my $custom = $options->{cache_key};
	$custom = $custom->($c) if ref($custom) eq 'CODE';
	return $custom if defined($custom) && !ref($custom) && length($custom);

	my $url = $c->req->url;
	my $host = $url->host_port // $c->req->headers->host // '';
	my $material = join "\x00", ref($c->app), $host, $url->path->to_string, $url->query->to_string;
	for my $name (@{$options->{vary_by} || []}) {
		$material .= "\x00" . lc($name) . '=' . ($c->req->headers->header($name) // '');
	}

	# A digest keeps the key short, driver-safe and free of cookie data
	return 'buffer:' . md5_sum($material);
}

sub _request_cacheable {
	my $c = shift;

	return 0 if $ENV{NO_CACHE} || $ENV{NO_STORE};

	my $method = $c->req->method;
	return 0 unless ($method eq 'GET') || ($method eq 'HEAD');

	# Authenticated responses are per-user, whatever the URL says
	return 0 if $c->req->headers->authorization;

	my $control = lc($c->req->headers->cache_control // '');
	return 0 if $control =~ /(?:^|,)\s*(?:no-store|no-cache|private|max-age\s*=\s*0)\b/;

	return 1;
}

sub _response_cacheable {
	my ($res, $options) = @_;

	my $headers = $res->headers;

	# Never replay cookies that were meant for one client
	return 0 if $headers->set_cookie;

	my $control = lc($headers->cache_control // '');
	return 0 if $control =~ /(?:^|,)\s*(?:no-store|private)\b/;

	# A response that varies on something that is not part of the key would
	# be served to the wrong client
	my %allowed = map { lc($_) => 1 } @{$options->{vary_by} || []};
	$allowed{'accept-encoding'} = 1;
	for my $name (split /,/, ($headers->vary // '')) {
		$name =~ s/^\s+//;
		$name =~ s/\s+$//;
		next unless length($name);
		return 0 unless $allowed{lc($name)};
	}

	return 1;
}

sub _headers_to_store {
	my $headers = shift;

	my %skip = map { lc($_) => 1 } qw(
		Connection Content-Encoding Content-Length Date ETag Keep-Alive
		Last-Modified Server Set-Cookie Transfer-Encoding X-Cache
	);

	my @pairs;
	for my $name (@{$headers->names}) {
		next if $skip{lc($name)};
		push @pairs, [$name, $_] for @{$headers->every_header($name)};
	}

	return \@pairs;
}

sub _script_mtime {
	my $state = shift;

	return $state->{script_mtime} if exists($state->{script_mtime});

	my $script = $0;
	my @stat = (defined($script) && length($script) && -f $script) ? stat($script) : ();

	return $state->{script_mtime} = @stat ? $stat[9] : undef;
}

# The newest mtime of the application and the templates.  Both Last-Modified
# and cache invalidation use this, so a template edit invalidates a page even
# though the application script has not changed.
sub _application_mtime {
	my ($c, $state) = @_;

	my $key = 'buffer.application_mtime';
	return $c->stash->{$key} if exists($c->stash->{$key});

	my $cache = $state->{options}{template_mtime_cache};
	my $cache_key;
	if ($cache) {
		$cache_key = _template_mtime_cache_key($c, $state);
		my $cached = eval { $cache->get($cache_key) };
		if (my $error = $@) {
			$c->app->log->debug("Buffer: template mtime cache get failed: $error");
		} elsif (defined($cached) && $cached =~ /^\d+$/) {
			return $c->stash->{$key} = $cached;
		}
	}

	my $latest = _script_mtime($state);
	my %seen;
	for my $dir (@{$c->app->renderer->paths || []}) {
		next unless defined($dir) && length($dir);
		$latest = _latest_mtime($dir, $latest, \%seen);
	}

	if ($cache && defined($latest)) {
		my $duration = $state->{options}{template_mtime_cache_duration};
		$duration = 10 unless defined($duration) && !ref($duration) && length($duration);
		my $stored = eval { $cache->set($cache_key, $latest, $duration) };
		if (my $error = $@) {
			$c->app->log->debug("Buffer: template mtime cache set failed: $error");
		} elsif (!$stored) {
			$c->app->log->debug('Buffer: template mtime cache did not store the scan');
		}
	}

	return $c->stash->{$key} = $latest;
}

sub _template_mtime_cache_key {
	my ($c, $state) = @_;

	my @parts = (ref($c->app), defined($0) ? $0 : '', _script_mtime($state) // '');
	push @parts, map { defined($_) ? $_ : '' } @{$c->app->renderer->paths || []};

	return 'buffer:template-mtime:' . md5_sum(join "\0", @parts);
}

# Include directory mtimes as well as file mtimes: editing a file moves the
# file's mtime, while adding, removing or renaming one moves its directory's.
# stat() follows symlinks, and the seen set stops a symlink loop.
sub _latest_mtime {
	my ($path, $latest, $seen) = @_;

	my @stat = stat($path);
	return $latest unless @stat;

	if (defined($stat[9]) && (!defined($latest) || ($stat[9] > $latest))) {
		$latest = $stat[9];
	}
	return $latest unless -d _;

	my $id = "$stat[0]:$stat[1]";
	return $latest if $seen->{$id}++;

	opendir(my $dh, $path) or return $latest;
	for my $entry (readdir $dh) {
		next if ($entry eq '.') || ($entry eq '..');
		$latest = _latest_mtime(File::Spec->catfile($path, $entry), $latest, $seen);
	}
	closedir($dh);

	return $latest;
}

sub _optimise {
	my ($self, $body, $c, $options) = @_;

	my $level = $options->{optimise_content} || 0;
	return $body unless $level;

	$body = _squash($body);

	if ($options->{rewrite_links}) {
		my $rewritten = _rewrite_links($body, $c);
		$body = $rewritten if defined($rewritten);
	}

	# Without HTML::Packer comments and embedded CSS/JavaScript cannot be
	# minified, but the white-space squashing above is still worth keeping
	return $body unless _module_available('HTML::Packer');

	my $minified = eval {
		require HTML::Packer;

		my $packer_options = {
			remove_comments => 1,
			remove_newlines => 0,
			do_stylesheet => 'minify',
		};
		if ($level >= 2) {
			$packer_options->{do_javascript} = 'best';
			$body =~ s/(<script.*?>)\s*<!--/$1/gi;
			$body =~ s/\/\/-->\s*<\/script>/<\/script>/gi;
			$body =~ s/(<script.*?>)\s+/$1/gi;
		}

		my $result = HTML::Packer->init->minify(\$body, $packer_options);

		if ($level >= 2) {
			# Turn document.write("a"); document.write("b") into
			# document.write("a"+"b"), stopping once it stops shrinking
			my $old_length = length($result);
			while (1) {
				$result =~ s/<script\s*?type\s*?=\s*?"text\/javascript"\s*?>(.*?)document\.write\((.+?)\);\s*?document\.write\((.+?)\)/<script type="text\/JavaScript">${1}document.write($2+$3)/igs;
				my $new_length = length($result);
				last if $new_length >= $old_length;
				$old_length = $new_length;
			}
		}

		$result;
	};
	if ($@) {
		$c->app->log->error("Buffer: HTML::Packer failed: $@");
		return $body;
	}

	return $minified;
}

# Reduce output, e.g. remove superfluous white-space.
# This is the same set of substitutions used by CGI::Buffer and FCGI::Buffer.
sub _squash {
	my $body = shift;

	$body =~ s/(((\s+|\r)\n|\n(\s+|\+)))/\n/g;
	$body =~ s/\<\/div\>\s+\<div/\<\/div\>\<div/gis;
	$body =~ s/(<div>\s+|\s+<div>)/<div>/gis;
	$body =~ s/\s+<\/div\>/\<\/div\>/gis;
	$body =~ s/\s+\<p\>|\<p\>\s+/\<p\>/im;
	$body =~ s/\s+\<\/p\>|\<\/p\>\s+/\<\/p\>/gis;
	$body =~ s/<html>\s+<head>/<html><head>/is;
	$body =~ s/\s*<\/head>\s+<body>\s*/<\/head><body>/is;
	$body =~ s/<html>\s+<body>/<html><body>/is;
	$body =~ s/<body>\s+/<body>/is;
	$body =~ s/\s+\<\/html/\<\/html/is;
	$body =~ s/\s+\<\/body/\<\/body/is;
	$body =~ s/\s(\<.+?\>\s\<.+?\>)/$1/;
	$body =~ s/\<p\>\s/\<p\>/gi;
	$body =~ s/\<\/p\>\s\<p\>/\<\/p\>\<p\>/gi;
	$body =~ s/\<\/tr\>\s\<tr\>/\<\/tr\>\<tr\>/gi;
	$body =~ s/\<\/td\>\s\<\/tr\>/\<\/td\>\<\/tr\>/gi;
	$body =~ s/\<\/td\>\s*\<td\>/\<\/td\>\<td\>/gis;
	$body =~ s/\<\/tr\>\s\<\/table\>/\<\/tr\>\<\/table\>/gi;
	$body =~ s/\<br\s?\/\>\s?\<p\>/\<p\>/gi;
	$body =~ s/\<br\>\s/\<br\>/gi;
	$body =~ s/\s+\<br/\<br/gi;
	$body =~ s/\<br\s?\/\>\s/\<br \/>/gi;
	$body =~ s/[ \t]+/ /gs;	# Don't use \s+, it breaks JavaScript
	$body =~ s/\s\<p\>/\<p\>/gi;
	$body =~ s/\s\<script/\<script/gi;
	$body =~ s/(<script>\s|\s<script>)/<script>/gis;
	$body =~ s/(<\/script>\s|\s<\/script>)/<\/script>/gis;
	$body =~ s/\<td\>\s/\<td\>/gi;
	$body =~ s/\s+\<a\shref="(.+?)"\>\s?/ <a href="$1">/gis;
	$body =~ s/\s?<a\shref=\s"(.+?)"\>/ <a href="$1">/gis;
	$body =~ s/\s+<\/a\>\s+/<\/a> /gis;
	$body =~ s/(\s?<hr>\s+|\s+<hr>\s?)/<hr>/gis;
	$body =~ s/<\/li>\s+<li>/<\/li><li>/gis;
	$body =~ s/<\/li>\s+<\/ul>/<\/li><\/ul>/gis;
	$body =~ s/<ul>\s+<li>/<ul><li>/gis;
	$body =~ s/\s+<\/li>/<\/li>/gis;
	$body =~ s/\<\/option\>\s+\<option/\<\/option\>\<option/gis;
	$body =~ s/<title>\s*(.+?)\s*<\/title>/<title>$1<\/title>/is;
	$body =~ s/<\/center>\s+<center>/ /gis;

	return $body;
}

sub _rewrite_links {
	my ($body, $c) = @_;

	my $url = eval { $c->req->url->to_abs };
	return undef unless $url;

	my $host = $url->host;
	return undef unless defined($host) && length($host);

	my $authority = $url->host_port // $host;
	my $scheme = $url->scheme // 'http';

	my $origin = quotemeta "$scheme://$authority";
	my $relative = quotemeta "//$authority";

	$body =~ s{<a\s+?href="$origin"}{<a href="/"}gim;
	$body =~ s{<a\s+?href="$origin/}{<a href="/}gim;
	$body =~ s{<a\s+?href="$relative/}{<a href="/}gim;
	$body =~ s{<img\s+?src="$origin"}{<img src="/"}gim;
	$body =~ s{<img\s+?src="$origin/}{<img src="/}gim;
	$body =~ s{<img\s+?src="$relative/}{<img src="/}gim;

	# A link to the current page with a query string only needs the query
	# string, e.g. href="/search?q=perl" becomes href="?q=perl"
	my $path = quotemeta $c->req->url->path->to_string;
	if (length($path) > 1) {
		$body =~ s{<a\s+?href="$path\?}{<a href="?}gim;
	}

	return $body;
}

# Pick the best content coding from an Accept-Encoding header.
# Returns undef when identity should be used.
sub _negotiate_encoding {
	my ($accept, $supported) = @_;

	return undef unless defined($accept) && length($accept);
	return undef unless $supported && @$supported;

	my (%quality, $wildcard);
	for my $part (split /\s*,\s*/, $accept) {
		next unless length($part);

		my ($token, @params) = split /\s*;\s*/, $part;
		next unless defined($token) && length($token);

		$token = lc $token;
		$token = 'gzip' if $token eq 'x-gzip';

		my $q = 1;
		for my $param (@params) {
			$q = $1 + 0 if $param =~ /^q\s*=\s*([0-9.]+)$/i;
		}
		$q = 0 if $q < 0;
		$q = 1 if $q > 1;

		if ($token eq '*') {
			$wildcard = $q;
		} elsif (!exists($quality{$token}) || ($q > $quality{$token})) {
			$quality{$token} = $q;
		}
	}

	my ($best, $best_quality);
	for my $encoding (@$supported) {
		my $q = exists($quality{$encoding}) ? $quality{$encoding} : (defined($wildcard) ? $wildcard : 0);
		next if $q <= 0;
		if (!defined($best_quality) || ($q > $best_quality)) {
			$best = $encoding;
			$best_quality = $q;
		}
	}

	return $best;
}

sub _encode_body {
	my ($encoding, $bytes) = @_;

	my $compressed;
	my $ok = eval {
		if ($encoding eq 'gzip') {
			$compressed = gzip($bytes);
		} elsif ($encoding eq 'br') {
			require IO::Compress::Brotli;
			$compressed = IO::Compress::Brotli::bro($bytes);
		} elsif ($encoding eq 'zstd') {
			require Compress::Zstd;
			$compressed = Compress::Zstd::compress(\$bytes);
		} else {
			die "unknown encoding $encoding";
		}
		1;
	};

	return (undef, $@) unless $ok;
	return (undef, undef) unless defined($compressed);
	return ($compressed, undef);
}

sub _etag_matches {
	my ($if_none_match, $etag) = @_;

	my $mine = $etag;
	$mine =~ s{^W/}{};
	for my $candidate (map { _trim($_) } split /,/, $if_none_match) {
		next unless length($candidate);
		return 1 if $candidate eq '*';
		$candidate =~ s{^W/}{};
		return 1 if $candidate eq $mine;
	}

	return 0;
}

sub _resolve_last_modified {
	my ($option, $c, $state) = @_;

	return undef unless $option;

	if (ref $option eq 'CODE') {
		my $value = $option->($c);
		return undef unless defined($value);
		return _resolve_last_modified($value, $c, $state);
	}

	return undef if ref $option;

	if ($option eq '1') {
		return _application_mtime($c, $state);
	}

	return $option + 0 if $option =~ /^\d+$/;

	my $epoch = eval { Mojo::Date->new($option)->epoch };

	return $epoch;
}

sub _add_vary {
	my $headers = shift;

	my $vary = $headers->vary // '';
	return if grep { lc($_) eq 'accept-encoding' } map { _trim($_) } split /,/, $vary;
	$headers->vary(length($vary) ? "$vary, Accept-Encoding" : 'Accept-Encoding');
}

sub _trim {
	my $value = shift;

	$value =~ s/^\s+//;
	$value =~ s/\s+$//;

	return $value;
}

sub _mime_type {
	my $content_type = shift;

	return undef unless defined($content_type) && length($content_type);
	$content_type =~ /^\s*([\w.+-]+\/[\w.+-]+)/ or return undef;

	return lc $1;
}

sub _matches {
	my ($type, $patterns) = @_;

	return 0 unless $patterns && ref($patterns) eq 'ARRAY';
	for my $pattern (@$patterns) {
		if (ref $pattern eq 'Regexp') {
			return 1 if $type =~ $pattern;
		} elsif (defined($pattern) && (lc($pattern) eq $type)) {
			return 1;
		}
	}

	return 0;
}

1;	# End of Mojolicious::Plugin::Buffer

=head1 DEPLOYMENT

=head2 Hypnotoad

L<hypnotoad> preloads the application before forking the workers, so the
plugin is registered once and every worker inherits the same cache object
and lock backend.  The cache storage, and the storage used by the lock
backend, must be shared and writable by the user that runs the workers.  The
example below uses L<CHI>, which must be installed in the application's
environment.

A complete application:

    package MyApp;
    use Mojo::Base 'Mojolicious';

    use CHI;

    sub startup {
        my $self = shift;

        $self->config(hypnotoad => {
            listen   => ['http://*:8080'],
            workers  => 4,
            pid_file => '/var/lib/myapp/hypnotoad.pid',
        });

        $self->plugin('Buffer' => {
            optimise_content => 1,
            cache => CHI->new(
                driver    => 'File',
                root_dir  => '/var/cache/myapp/buffer',
                namespace => 'pages',
            ),
            cache_lock_dir => '/var/lib/myapp/buffer-locks',
            cache_duration => '10 minutes',
        });

        $self->routes->get('/expensive' => sub {
            my $c = shift;
            return if $c->buffer_is_cached;

            # ... expensive work ...

            $c->render(template => 'expensive');
        });
    }

    1;

A runnable copy of this example, with its paths under C<eg/hypnotoad>, is
included as F<eg/hypnotoad>.

C<script/my_app> is the usual launcher:

    #!/usr/bin/env perl
    use strict;
    use warnings;
    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use MyApp;

    MyApp->new->start;

Create the directories as the deployment user and start the server:

    install -d -o www-data -g www-data -m 0750 /var/cache/myapp/buffer
    install -d -o www-data -g www-data -m 0750 /var/lib/myapp /var/lib/myapp/buffer-locks
    hypnotoad script/my_app

Replace C<www-data> with the unprivileged user that runs the workers; do not
run hypnotoad as root.  The plugin creates C<cache_lock_dir> if necessary,
but pre-creating it as the deployment user sets its ownership and
permissions.  The cache directory must be writable by that user too.  Use
C<hypnotoad -f script/my_app> in the foreground while testing, and
C<hypnotoad -s script/my_app> to stop it.

=head2 Cache and lock requirements

For workers on the same host, L<CHI>'s C<File> driver and the built-in file
lock backend work.  Do not use C<Memory>, and do not put a per-worker C<L1>
cache in front of the shared cache: a waiting worker would not see the entry
built by another worker and would eventually receive C<503 Service
Unavailable>.  A shared filesystem with reliable C<flock> can also be used
on several hosts.

=head2 Multiple hosts

Workers on different hosts need a shared cache and a lock backend that does
not rely on C<flock>.  This example uses CHI's Memcached driver for the cache
and L<Mojolicious::Plugin::Buffer::Lock::Redis> for the lock, with the
L<Redis> client:

    use CHI;
    use Mojolicious::Plugin::Buffer::Lock::Redis;
    use Redis;

    my $redis = sub {
        Redis->new(
            server        => 'redis://redis.internal:6379',
            cnx_timeout   => 1,
            read_timeout  => 1,
            write_timeout => 1,
        );
    };

    $app->plugin('Buffer' => {
        cache => CHI->new(
            driver    => 'Memcached',
            servers   => ['cache1.internal:11211', 'cache2.internal:11211'],
            namespace => 'pages',
        ),
        cache_lock => Mojolicious::Plugin::Buffer::Lock::Redis->new(
            redis     => $redis,
            namespace => 'myapp:buffer:',
            ttl       => 60,
        ),
        cache_duration => '10 minutes',
    });

The C<ttl> must be longer than L</cache_lock_timeout> and longer than the
slowest cached action.  If it expires while the builder is still working,
another worker can start building the same entry.  The Redis client is
called synchronously, so set short connect, read and write timeouts.  The
code reference is called once per worker, after the fork; a connection
created in C<startup> would be shared by every worker and must not be used.
CHI's Memcached driver needs L<Cache::Memcached::Fast>.

Only cache pages that are identical for every visitor.  The default key
includes the C<Cookie> header, not the contents of the session, so a page
that depends on the session needs L</cache_key> or a suitable L</vary_by>
list.  Entries are discarded when the application script or a template
changes, and otherwise expire after L</cache_duration>.

=head1 NOTES

=head2 Testing

The Redis lock backend has an optional live integration test.  It skips when
C<MPB_REDIS_URL> (or C<REDIS_SERVER>) is not set, or when neither L<Redis> nor
L<Redis::Fast> is installed.  Redis::Fast is used when it is the only client
available.  CI runs the test against a live Redis service with each client,
once with L<Redis> and once with only L<Redis::Fast> available (L<Redis>
hidden with L<Test::Without::Module>), and each run proves from the test
output which client it used, so both paths include the three-process crash
check described below rather than merely being wired up.  When either
variable is set, the test expects that server to be reachable; the value may
be a C<redis://> URL or a bare C<host:port>, so C<REDIS_SERVER> already in
the environment needs no rewriting:

    MPB_REDIS_URL=redis://127.0.0.1:6379 prove -Ilib t/76-live-redis.t
    REDIS_SERVER=127.0.0.1:6379 prove -Ilib t/76-live-redis.t

A server named by either variable must answer.  The variable says a live
Redis is there for this test, so an unreachable one fails the file, naming
the variable and the connection error, rather than skipping and looking like
a checkout with no Redis configured.  Unset both to skip the test.

That includes a three-process check of the crash path: a worker takes the
lock and is killed, another process stays blocked until the TTL expires,
takes the lock over, and a third process is blocked until that owner
releases it.  The crash test uses a two second lock TTL and waits for it to
run out rather than sleeping a fixed margin; set C<MPB_REDIS_TTL> to widen
that further on a heavily loaded machine.  The normal test suite does not
require a Redis server.

=head2 Why a plugin?

L<CGI::Buffer> replaces C<STDOUT> with an in-memory buffer and does its work
in an C<END> block, and L<FCGI::Buffer> buffers each FastCGI request and does
its work in C<DESTROY>.  Neither trick is needed in Mojolicious: the response
already exists as an object before it is written, so the plugin can simply
hook C<after_dispatch> and rewrite it.  That gives the same effect without a
source filter, without reading C<$_>, and without depending on a specific
server or environment.

=head2 Interaction with the renderer

C<Mojolicious::Renderer> compresses rendered output with gzip by default
(C<compress> is on and C<min_compress_size> is 860 bytes).  That happens
before L<Mojolicious/"after_dispatch"> is emitted, which would leave this
plugin with nothing to optimise and no C<ETag> to generate on any page
larger than 860 bytes.  Registering this plugin therefore calls
C<< $app->renderer->compress(0) >>, and the plugin does the compression
instead - with gzip, Brotli or Zstandard as negotiated, and with the header
work the renderer does not do.  If you enable C<< $app->renderer->compress >>
after loading the plugin, those responses will be skipped by the plugin.

=head2 What is not implemented

C<save_to>, which rewrites dynamic pages into static ones, is a site
generation feature rather than a response filter and is not part of this
plugin.  The server-side cache is available as the opt-in
L</buffer_is_cached> helper described above.

=head1 CAVEATS

=over 4

=item * Only in-memory responses are processed.  Static files
(C<Mojo::Asset::File>) and streaming responses are left alone.

=item * Responses that already have a C<Content-Encoding>, for example from
C<$app-E<gt>renderer-E<gt>compress>, are not compressed again.

=item * Gzip, Brotli, Zstandard and identity representations have different
C<ETag>s, because the tag identifies the selected representation.  A client
that switches between content codings will therefore download the page once
for each coding.

=item * Because the body is buffered, the plugin must not be used for
responses that are streamed with C<$c-E<gt>write> (server-sent events,
long-polling and so on).  C<text/event-stream> is excluded by default.

=item * Optimising HTML rewrites the document.  Use
C<optimise_content =E<gt> 0> on pages where every byte matters to scripts, or
disable it per response with C<$c-E<gt>stash(buffer =E<gt> {optimise_content =E<gt> 0})>.

=item * The server-side cache is opt-in: a page is only stored if its action
calls L</buffer_is_cached>.  An action that forgets to call it is never
cached, and an action that calls it for a personalised page must supply a
L</cache_key> that distinguishes users (the default key only includes the
C<Cookie> header, not the session contents).

=item * The default key includes the C<Cookie> header, so each session gets
its own set of entries and anonymous visitors share them.  Sites that set an
analytics cookie on every visit will get little sharing; use
C<vary_by =E<gt> []> for genuinely public pages, or L</cache_key>.

=item * Single-flight is per worker by default.  Each C<hypnotoad> worker
keeps its own in-flight table, so a cold entry can be built once per worker;
set L</cache_lock> or L</cache_lock_dir> to coalesce across workers, with a
shared cache.  A request waiting on an in-flight response is answered with
C<503> if that
response fails, cannot be cached, or exceeds L</cache_lock_timeout>, rather
than running the action a second time.

=item * Entries are invalidated when the application script or a template
path changes, but not when data or configuration changes.  The TTL is the
backstop for those.

=back

=head1 SEE ALSO

L<CGI::Buffer>, L<FCGI::Buffer>, L<CHI>, L<HTML::Packer>,
L<Mojolicious::Plugin>, L<Mojolicious::Plugin::Buffer::Lock::File>,
L<Mojolicious::Plugin::Buffer::Lock::Redis>

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option)
any later version.

=cut
