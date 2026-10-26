## Name

Mojolicious::Plugin::Buffer - Optimise, compress and validate Mojolicious responses

## Version

Version 0.001.0

## Synopsis

```perl
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
```

The same plugin in a full Mojolicious application:

```perl
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
```

Compression is negotiated from the `Accept-Encoding` request header, so
nothing extra is needed in your actions - a client that accepts gzip gets
gzip, everyone else gets the uncompressed response.

A server-side cache is optional and opt-in per action.  Give the plugin any
object that understands `get()`, `set()` and `remove()`, such as [CHI](https://metacpan.org/pod/CHI),
and call the helper before doing any work:

```perl
use CHI;
plugin 'Buffer' => {cache => CHI->new(driver => 'File')};

get '/expensive' => sub {
    my $c = shift;
    return if $c->buffer_is_cached;   # the cached response has been sent
    # ... do the expensive work ...
    $c->render(template => 'expensive');
};
```

To turn the plugin off, or to override its options, for a single response,
put a `buffer` value in the stash:

```perl
# Don't touch this response at all (e.g. it is already compressed,
# or the user is downloading it)
$c->stash(buffer => 0);

# Use different options for this response
$c->stash(buffer => {compress_content => 0, optimise_content => 0});
```

## Description

`Mojolicious::Plugin::Buffer` is the Mojolicious equivalent of
[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer) and [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer).  It buffers the response that your
application has produced, then, before it is sent:

- optimises HTML by removing superfluous white space and comments,
minifying embedded CSS and JavaScript, and replacing links back to your own
site with relative links;
- compresses the response with whichever of Brotli, Zstandard or gzip
the client prefers and the server supports;
- adds `ETag`, `Last-Modified` and `Vary` headers, and answers
`If-None-Match` conditional requests, or `If-Modified-Since` when no
`ETag` is generated, with `304 Not Modified`;
- sets an accurate `Content-Length` after the above changes;
- optionally stores the finished page in a server-side cache and
replays it for later requests, so that an action can skip its expensive
work entirely (see ["buffer\_is\_cached"](#buffer_is_cached)).

Unlike the CGI modules there is no source filter and no `END` block: a
Mojolicious plugin can see the finished response through a hook, so the same
effect is achieved without buffering `STDOUT` or guessing the environment.
The plugin hooks `after_dispatch`, which is emitted once for every
response, after the renderer has put the content into the response and
before the transaction is resumed.  This means it also sees responses
that were built with `$c->res->body` rather than `$c->render`.

## Options

All options can be given to `plugin()` and, except where noted, overridden
per request through the `buffer` stash value.

### Compress\_Content

Compress eligible responses, defaults to 1.  Set to 0 to only optimise (and
remember that the plugin turns off ["compress" in Mojolicious::Renderer](https://metacpan.org/pod/Mojolicious%3A%3ARenderer#compress), so a
response will then not be compressed at all).  The encodings offered to
clients are controlled by ["encodings"](#encodings).

Like ["optimise\_content"](#optimise_content), it can be declared once for a group of pages, which
is the point of a section that serves files it has already compressed:

```perl
my $assets = $r->under('/assets')->to(compress_content => 0);

package MyApp::Controller::Assets;
use Mojo::Base 'Mojolicious::Controller';
has buffer_compress_content => 0;
```

A route default raises or lowers it for that route, the declaration beats the
plugin option, and the `buffer` stash overrides both.

### Optimise\_Content

How hard to optimise HTML, defaults to 0 (off):

- 0 - leave the HTML alone
- 1 - remove superfluous white space, rewrite same-site links and, when
[HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker) is installed, remove comments and minify embedded CSS
- 2 - as 1, plus aggressive JavaScript minification when [HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker)
is installed, which can break scripts that rely on the
`<!-- ... -->` hiding technique

Optimisation only applies to `text/html` and `application/xhtml+xml`
responses.  [HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker) is optional: without it the white-space
squashing and link rewriting still run, but comments and embedded CSS and
JavaScript are left alone, as they are by [CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer) and
[FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer).  Install [HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker) for the full effect.

Like ["trust\_last\_modified"](#trust_last_modified), it can be declared once for a group of pages,
as a route default, an `under` route or a controller method:

```perl
$r->get('/about' => {optimise_content => 1} => sub {...});
my $docs = $r->under('/docs')->to(optimise_content => 1);

package MyApp::Controller::Docs;
use Mojo::Base 'Mojolicious::Controller';
has buffer_optimise_content => 1;
```

A declaration beats the plugin option, a route default of `0` turns
optimisation off inside a group that has it on, and the `buffer` stash
overrides both.

### Rewrite\_Links

When optimising, rewrite `<a href>` and `<img src>` links that
point at the current site as absolute URLs into root-relative links, and
links to the current script with a query string into just the query string.
Defaults to 1.  Has no effect unless ["optimise\_content"](#optimise_content) is enabled.

It is declared for a group of pages in the same way as ["optimise\_content"](#optimise_content),
which matters for a section whose HTML is not used in place: a preview of a
newsletter or a page rendered for another site needs its absolute URLs kept
while still being optimised elsewhere.

```perl
my $preview = $r->under('/preview')->to(optimise_content => 1, rewrite_links => 0);
```

### Generate\_Etag

Add an `ETag` header to `200` responses to `GET` and `HEAD` requests,
defaults to 1.  The tag is the MD5 of the response body before compression,
with a suffix for the content coding, so a gzip and an identity
representation of the same page have different tags.

Unlike ["optimise\_content"](#optimise_content), this is not declarable for a group of pages: it
is a per-endpoint decision about whether a digest is worth computing, not a
policy for a section of the site.  Skip the digest for one response with
`$c->stash(buffer => {generate_etag => 0})`, or for the whole
application with the plugin option.

### Generate\_304

Answer conditional requests with `304 Not Modified` when the
`If-None-Match` header matches, defaults to 1.  `If-None-Match` takes
precedence over `If-Modified-Since`, as required by RFC 7232.

`If-Modified-Since` is only used when no `ETag` is generated for the
response, which means ["generate\_etag"](#generate_etag) is off, unless ["trust\_last\_modified"](#trust_last_modified)
opts back in.  `Last-Modified` is derived from the application and its
templates, and says nothing about the data a page was rendered from: a
database row or a stash value can change while the template stays untouched.
A 304 on the timestamp alone would tell such a client that its stale copy is
current, so with an `ETag` available only the tag can revalidate the
response.  Clients that have the tag, which includes browsers after the first
`200`, send `If-None-Match` and are unaffected.

Like ["generate\_etag"](#generate_etag), this is not declarable for a group of pages.  It is
the switch that decides whether a client is told its copy is current, and a
group that also sets ["trust\_last\_modified"](#trust_last_modified) would contradict itself if it
could turn the answer off as well.  Use
`$c->stash(buffer => {generate_304 => 0})` where one endpoint must always
send a body.

### Last\_Modified

Add a `Last-Modified` header, and honour `If-Modified-Since` when no
`ETag` is generated (see ["generate\_304"](#generate_304)) or ["trust\_last\_modified"](#trust_last_modified) is
set, defaults to 1, which uses the newest modification time of the
application script (`$0`) and the renderer's template files and directories.
May be:

- 0 - do not generate the header
- 1 - use the newest modification time of the application script
(`$0`) and the files and directories under the renderer's template paths
- a number - a Unix epoch
- a date string - anything [Mojo::Date](https://metacpan.org/pod/Mojo%3A%3ADate) can parse
- a coderef - called with the controller, returns any of the above

The value is ignored for responses that are not `200` responses to
`GET` or `HEAD` requests.  If `If-None-Match` is present it takes
precedence over `If-Modified-Since`, as required by RFC 7232.

The default is the newest mtime of the application file and the files and
directories under the renderer's `paths`, so editing a template changes
`Last-Modified` and discards cache entries built from the old one.  `morbo`
and `hypnotoad` set `$0` to your application script, but under a PSGI or
module-only deployment it may be the wrapper instead; pass an explicit epoch
or a coderef there.  The template paths are scanned once per request, unless
["template\_mtime\_cache"](#template_mtime_cache) is configured, so for a large tree or an application
that does not use templates, an explicit epoch or coderef is cheaper.
Database rows and other inputs are not covered; use a coderef for pages whose
freshness depends on them, or set `last_modified => 0` and rely on
["generate\_etag"](#generate_etag) alone.  A page whose data changes without its template
changing is never answered with a 304 from this timestamp while an `ETag` is
generated, but the header itself still only describes the code, so a client
that keeps `If-Modified-Since` without the tag will keep refetching it.

### Trust\_Last\_Modified

Answer `If-Modified-Since` even when an `ETag` is generated, defaults to 0.
Only enable it for pages whose body is a function of the application and its
templates, with no database rows, session values or other inputs that can
change under an untouched template.

["last\_modified"](#last_modified) describes the code, not the body, which is why
`If-Modified-Since` is otherwise ignored while a tag exists.  Turning this
on restores timestamp revalidation for clients that send only
`If-Modified-Since`, so a page rendered from its templates alone can be
revalidated by those clients without a tag.  `If-None-Match` still takes
precedence, so a client holding the tag is still protected from a stale copy
even here:

```perl
plugin 'Buffer' => {
    trust_last_modified => 1,   # this application only renders templates
};
```

Use it per response instead with `$c->stash(buffer => {trust_last_modified
&#x3d;> 1})` when only some pages are that predictable.

A whole group of pages can opt in once.  The easiest way is a route default,
which [Mojolicious](https://metacpan.org/pod/Mojolicious) copies into the stash:

```perl
# one route
$r->get('/about' => {trust_last_modified => 1} => sub {...});

# everything beneath an under route
my $docs = $r->under('/docs')->to(trust_last_modified => 1);
$docs->get('/intro' => sub {...});
```

A controller can declare it for itself and, through a base class, for its
whole namespace:

```perl
package MyApp::Controller::Docs;
use Mojo::Base 'Mojolicious::Controller';
has buffer_trust_last_modified => 1;

sub intro { shift->render(template => 'docs/intro') }
```

A plain `sub buffer_trust_last_modified { 1 }` works too, for a value that
depends on something the controller knows at request time.

A route default wins over the controller declaration, so a route default of
`0` opts one page back out of a trusting namespace, and the `buffer` stash
overrides both.  The declaration has no effect when ["generate\_304"](#generate_304) is off,
and it cannot make a page safe: it only says that the application and its
templates really are the only inputs.  ["optimise\_content"](#optimise_content) can be declared
for a group in the same way.

### Last-Modified Performance

The scan costs one `stat()` per file and directory under the renderer's
paths.  On a tree of 10,000 templates in 100 directories, a request using the
default scan took about 40 milliseconds of CPU on the machine used for these
measurements, against about 1 millisecond for the same request with an
explicit epoch; that is roughly 4 microseconds per tree entry.  With
["template\_mtime\_cache"](#template_mtime_cache) in front of it, the same request also took about 1
millisecond, the cache lookup adding only a few tens of microseconds, so the
middle ground gives up roughly 2% of the scan's cost to keep template
awareness.  The numbers are indicative, not a promise, and a faster or slower
filesystem will move them.  Run `benchmarks/last_modified.pl` with your own
tree size to measure all three variants.

Use an explicit epoch or a coderef when template changes do not need to move
`Last-Modified` and you do not rely on response-cache invalidation after a
template edit.  Use ["template\_mtime\_cache"](#template_mtime_cache) when you need template awareness
but not a scan on every request: it costs one cache lookup per request and
bounds how long a template edit can be missed by its duration.

### Template\_Mtime\_Cache

An optional cache object understanding `get()` and `set()`, such as a
[CHI](https://metacpan.org/pod/CHI) instance, used to remember the result of the template mtime scan.
Defaults to undef, which scans the renderer's template paths on every
request.  A per-worker cache avoids the scan without sharing anything:

```perl
use CHI;
plugin 'Buffer' => {
    template_mtime_cache => CHI->new(driver => 'Memory', datastore => {}),
};
```

A shared cache, such as CHI's File or Memcached driver, also avoids the scan
for every worker.  Entries are keyed by the application class, the
application script and its mtime, and the renderer's template paths, and are
stored with ["template\_mtime\_cache\_duration"](#template_mtime_cache_duration).  A cache failure is logged at
debug level and the scan runs as usual, so a broken cache cannot stop a
response.

For a large tree this is the middle ground: it avoids the per-request scan
described under ["Last-Modified performance"](#last-modified-performance) while still noticing template
changes, at the cost of up to one duration of staleness.

The cached value is only refreshed when the entry expires.  A template edit
therefore is not noticed until then, and neither `Last-Modified` nor the
cache invalidation described under ["last\_modified"](#last_modified) sees it immediately.
Keep ["template\_mtime\_cache\_duration"](#template_mtime_cache_duration) short if templates change often.

This option and ["template\_mtime\_cache\_duration"](#template_mtime_cache_duration) are read when the plugin is
registered; they cannot be overridden through the `buffer` stash.

### Template\_Mtime\_Cache\_Duration

How long a template mtime is kept, defaults to 10 seconds.  It is passed to
the cache's `set()`, so for [CHI](https://metacpan.org/pod/CHI) it may be a number of seconds or a
human-readable duration.

### Min\_Compress\_Size

Do not compress bodies smaller than this many bytes, defaults to 32.
Compression is also skipped if it would not make the body smaller.

### Encodings

An arrayref of the content codings to offer, in server preference order.
Defaults to `[qw(br zstd gzip)]`.  `br` is only offered if
[IO::Compress::Brotli](https://metacpan.org/pod/IO%3A%3ACompress%3A%3ABrotli) is installed and `zstd` only if [Compress::Zstd](https://metacpan.org/pod/Compress%3A%3AZstd)
is installed; gzip is always available.  Clients pick with the usual
quality values, and `identity` is used when nothing acceptable is offered.

### Compressible\_Types

An arrayref of media types to compress, defaults to `text/*`,
`application/json`, `application/javascript`, `application/xml`,
`application/xhtml+xml`, `image/svg+xml` and a few close relatives.
Entries may be strings (matched exactly, case-insensitively) or regular
expressions.

### Excluded\_Types

An arrayref of media types that are never buffered, defaults to
`text/event-stream`.  Entries may be strings or regular expressions.

### Cache

An optional cache object understanding `get()`, `set()` and `remove()`,
such as a [CHI](https://metacpan.org/pod/CHI) instance.  Defaults to undef, which disables the
server-side cache.  See ["buffer\_is\_cached"](#buffer_is_cached) for the rules about what is
cached and how keys are made.

### Cache\_Duration

How long entries are kept in the cache, defaults to `'10 minutes'`.  It is
passed to the cache's `set()`, so for [CHI](https://metacpan.org/pod/CHI) it may be a number of seconds
or a human-readable duration.

### Cache\_Key

A string, or a coderef called with the controller, that overrides the
generated cache key.  Useful when several URLs should share one entry, or
when the response depends on something the default key does not cover.

### Cache\_Single\_Flight

Only let one request at a time build a missing entry, defaults to 1.  When a
request misses the cache while another request in the same worker is already
building the same key, the second request waits for the first one to finish
and is then served the finished entry, without running the action.  This
matters for asynchronous actions: a synchronous action runs to completion
without the event loop doing anything else, so it cannot overlap with
another request in the same worker.

If the first request fails, produces a response that cannot be cached (for
example one that sets a cookie), or takes longer than ["cache\_lock\_timeout"](#cache_lock_timeout),
the waiting request is answered with `503 Service Unavailable` and
`Retry-After: 1` rather than running the action itself.  Set to 0 to let
every concurrent miss run the action independently.

By default the in-flight table is per worker process, so with N [hypnotoad](https://metacpan.org/pod/hypnotoad)
workers a cold entry can still be built up to N times.  Set ["cache\_lock"](#cache_lock) or
["cache\_lock\_dir"](#cache_lock_dir) to elect a single builder across processes instead.

### Cache\_Lock

An optional object that elects one process to build a missing entry, for
workers that cannot share a directory.  It must implement:

- acquire

    ```perl
    my ($guard, $error) = $lock->acquire($key);
    ```

    Return a truthy guard if the lock was acquired, `(undef, undef)` if another
    process holds it, and `(undef, $error)` if the backend failed.  On an error
    the plugin logs the message and continues with a per-worker flight, so a
    cache miss is still built.

    The call is synchronous and runs before the action is allowed to continue.
    A backend must therefore be quick and must not depend on the event loop; an
    asynchronous Redis client is not suitable.

- release

    ```
    $lock->release($guard);
    ```

    Release a guard returned by `acquire`.  The guard is opaque to the plugin.
    Releasing a lock that has already expired is allowed.  If release fails, the
    lock should expire on its own; the backend can return `(0, $error)` so the
    failure is logged.

The cache itself must still be shared between the workers.  The built-in
backends are [Mojolicious::Plugin::Buffer::Lock::File](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3AFile), selected with
["cache\_lock\_dir"](#cache_lock_dir), and [Mojolicious::Plugin::Buffer::Lock::Redis](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3ARedis).
`cache_lock` cannot be combined with ["cache\_lock\_dir"](#cache_lock_dir), and is read when
the plugin is registered rather than per response.

### Cache\_Lock\_Timeout

How long a request may wait for another request, in this worker or another
one, to build the same entry.  Defaults to 10 seconds.  It also bounds how
long a key is considered to be in flight when the request building it never
finishes.  Fractional seconds are allowed, so `0.5` is valid.

### Cache\_Lock\_Dir

A directory in which to keep lock files used to coalesce cache misses across
worker processes, defaults to undef, which limits single-flight to one worker.
This selects the built-in [Mojolicious::Plugin::Buffer::Lock::File](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3AFile) backend
and is a shorthand for `cache_lock =>
Mojolicious::Plugin::Buffer::Lock::File->new(dir => $dir)`.  The
plugin creates the directory if necessary.  It cannot be combined with
["cache\_lock"](#cache_lock).

The workers must share this directory and the cache itself.  A per-worker
cache such as CHI's `Memory` driver cannot be used, because a request in one
worker cannot see the entry built in another; disable any per-worker `L1`
cache in front of a shared cache for the same reason.  Locks are non-blocking
`flock`s on one small, empty file per cache key, so they are released
automatically if a worker dies.  The files are not removed, although they are
tiny and can be deleted while the application is stopped.  Use a private
directory.

This works for [hypnotoad](https://metacpan.org/pod/hypnotoad) workers on the same host, or on a shared
filesystem that implements `flock` reliably.  For workers on different
hosts, use ["cache\_lock"](#cache_lock) with
[Mojolicious::Plugin::Buffer::Lock::Redis](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3ARedis) instead.  It is read when the
plugin is registered, not per response.

### Vary\_by

An arrayref of request header names that become part of the generated cache
key.  Defaults to `['cookie']`, which keeps one client's session from being
served to another.  Set it to `[]` for URL-only caching of pages that are
identical for every visitor, or add e.g. `'accept-language'` when the
response varies by language.  Headers listed here may also appear in the
response's `Vary` header; a response that varies on anything else is not
stored.

## Methods

`Mojolicious::Plugin::Buffer` inherits all methods from
[Mojolicious::Plugin](https://metacpan.org/pod/Mojolicious%3A%3APlugin) and implements the following new one.  It also adds
the ["buffer\_is\_cached"](#buffer_is_cached) helper to the application.

### Register

```perl
$plugin->register(Mojolicious->new, {optimise_content => 1});Register the plugin, usually through C<$app-E<gt>plugin('Buffer', ...)>.
Croaks if an unknown option is given or an option has the wrong shape.
```

### Buffer\_Is\_Cached

```perl
get '/expensive' => sub {
    my $c = shift;
    return if $c->buffer_is_cached;
    # ... expensive work ...
    $c->render(template => 'expensive');
};
```

Look for a cached response and, if there is one, replay its status, headers
and body, add `X-Cache: HIT`, finish the response and return true.  The
action only has to return; no rendering is needed on a hit.  On a miss it
adds `X-Cache: MISS`, returns false, and the response is stored when it is
complete.

Only `200` responses to `GET` and `HEAD` requests are cached.  Requests
with an `Authorization` header or a `Cache-Control` header containing
`no-store`, `no-cache`, `private` or `max-age=0` bypass the cache, as do
requests made while the `NO_CACHE` or `NO_STORE` environment variable is
set.  Responses that set a cookie, that are marked `no-store` or
`private`, or that vary on something not listed in ["vary\_by"](#vary_by), are not
stored.  Entries created before the application script or any template file
or directory was last modified are treated as misses and removed.

The stored body is the optimised but uncompressed entity, so every hit is
compressed for the requesting client, gets its own `ETag` and can still be
answered with `304 Not Modified`.  The cache key is a digest of the
application class, host, path, query string and the values of the headers
listed in ["vary\_by"](#vary_by); use ["cache\_key"](#cache_key) to replace it.  Query argument order
is significant.

Concurrent misses for the same key are coalesced within a worker, or across
workers when ["cache\_lock"](#cache_lock) or ["cache\_lock\_dir"](#cache_lock_dir) is set: while one request
is building an entry, later requests wait for it and replay the result
instead of running the action again.  The waiting requests are held asynchronously, so this
works for actions that themselves use the event loop.  See
["cache\_single\_flight"](#cache_single_flight) for the failure and timeout behaviour.

Calling the helper more than once is harmless, but only the first call can
hit.  To disable the cache for one response, use
`$c->stash(buffer => {cache => undef})` before calling it.

## Deployment

### Hypnotoad

[hypnotoad](https://metacpan.org/pod/hypnotoad) preloads the application before forking the workers, so the
plugin is registered once and every worker inherits the same cache object
and lock backend.  The cache storage, and the storage used by the lock
backend, must be shared and writable by the user that runs the workers.  The
example below uses [CHI](https://metacpan.org/pod/CHI), which must be installed in the application's
environment.

A complete application:

```perl
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
```

A runnable copy of this example, with its paths under `eg/hypnotoad`, is
included as `eg/hypnotoad`.

`script/my_app` is the usual launcher:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use MyApp;

MyApp->new->start;
```

Create the directories as the deployment user and start the server:

```
install -d -o www-data -g www-data -m 0750 /var/cache/myapp/buffer
install -d -o www-data -g www-data -m 0750 /var/lib/myapp /var/lib/myapp/buffer-locks
hypnotoad script/my_app
```

Replace `www-data` with the unprivileged user that runs the workers; do not
run hypnotoad as root.  The plugin creates `cache_lock_dir` if necessary,
but pre-creating it as the deployment user sets its ownership and
permissions.  The cache directory must be writable by that user too.  Use
`hypnotoad -f script/my_app` in the foreground while testing, and
`hypnotoad -s script/my_app` to stop it.

### Cache and Lock Requirements

For workers on the same host, [CHI](https://metacpan.org/pod/CHI)'s `File` driver and the built-in file
lock backend work.  Do not use `Memory`, and do not put a per-worker `L1`
cache in front of the shared cache: a waiting worker would not see the entry
built by another worker and would eventually receive `503 Service
Unavailable`.  A shared filesystem with reliable `flock` can also be used
on several hosts.

### Multiple Hosts

Workers on different hosts need a shared cache and a lock backend that does
not rely on `flock`.  This example uses CHI's Memcached driver for the cache
and [Mojolicious::Plugin::Buffer::Lock::Redis](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3ARedis) for the lock, with the
[Redis](https://metacpan.org/pod/Redis) client:

```perl
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
```

The `ttl` must be longer than ["cache\_lock\_timeout"](#cache_lock_timeout) and longer than the
slowest cached action.  If it expires while the builder is still working,
another worker can start building the same entry.  The Redis client is
called synchronously, so set short connect, read and write timeouts.  The
code reference is called once per worker, after the fork; a connection
created in `startup` would be shared by every worker and must not be used.
CHI's Memcached driver needs [Cache::Memcached::Fast](https://metacpan.org/pod/Cache%3A%3AMemcached%3A%3AFast).

Only cache pages that are identical for every visitor.  The default key
includes the `Cookie` header, not the contents of the session, so a page
that depends on the session needs ["cache\_key"](#cache_key) or a suitable ["vary\_by"](#vary_by)
list.  Entries are discarded when the application script or a template
changes, and otherwise expire after ["cache\_duration"](#cache_duration).

## Notes

### Testing

The Redis lock backend has an optional live integration test.  It skips when
`MPB_REDIS_URL` (or `REDIS_SERVER`) is not set, or when neither [Redis](https://metacpan.org/pod/Redis) nor
[Redis::Fast](https://metacpan.org/pod/Redis%3A%3AFast) is installed.  Redis::Fast is used when it is the only client
available.  CI runs the test against a live Redis service with each client,
once with [Redis](https://metacpan.org/pod/Redis) and once with only [Redis::Fast](https://metacpan.org/pod/Redis%3A%3AFast) available ([Redis](https://metacpan.org/pod/Redis)
hidden with [Test::Without::Module](https://metacpan.org/pod/Test%3A%3AWithout%3A%3AModule)), and each run proves from the test
output which client it used, so both paths include the three-process crash
check described below rather than merely being wired up.  When either
variable is set, the test expects that server to be reachable; the value may
be a `redis://` URL or a bare `host:port`, so `REDIS_SERVER` already in
the environment needs no rewriting:

```
MPB_REDIS_URL=redis://127.0.0.1:6379 prove -Ilib t/76-live-redis.t
REDIS_SERVER=127.0.0.1:6379 prove -Ilib t/76-live-redis.t
```

A server named by either variable must answer.  The variable says a live
Redis is there for this test, so an unreachable one fails the file, naming
the variable and the connection error, rather than skipping and looking like
a checkout with no Redis configured.  Unset both to skip the test.

That includes a three-process check of the crash path: a worker takes the
lock and is killed, another process stays blocked until the TTL expires,
takes the lock over, and a third process is blocked until that owner
releases it.  The crash test uses a two second lock TTL and waits for it to
run out rather than sleeping a fixed margin; set `MPB_REDIS_TTL` to widen
that further on a heavily loaded machine.  The normal test suite does not
require a Redis server.

### Why a Plugin?

[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer) replaces `STDOUT` with an in-memory buffer and does its work
in an `END` block, and [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer) buffers each FastCGI request and does
its work in `DESTROY`.  Neither trick is needed in Mojolicious: the response
already exists as an object before it is written, so the plugin can simply
hook `after_dispatch` and rewrite it.  That gives the same effect without a
source filter, without reading `$_`, and without depending on a specific
server or environment.

### Interaction With the Renderer

`Mojolicious::Renderer` compresses rendered output with gzip by default
(`compress` is on and `min_compress_size` is 860 bytes).  That happens
before ["after\_dispatch" in Mojolicious](https://metacpan.org/pod/Mojolicious#after_dispatch) is emitted, which would leave this
plugin with nothing to optimise and no `ETag` to generate on any page
larger than 860 bytes.  Registering this plugin therefore calls
`$app->renderer->compress(0)`, and the plugin does the compression
instead - with gzip, Brotli or Zstandard as negotiated, and with the header
work the renderer does not do.  If you enable `$app->renderer->compress`
after loading the plugin, those responses will be skipped by the plugin.

### What Is Not Implemented

`save_to`, which rewrites dynamic pages into static ones, is a site
generation feature rather than a response filter and is not part of this
plugin.  The server-side cache is available as the opt-in
["buffer\_is\_cached"](#buffer_is_cached) helper described above.

## Caveats

- Only in-memory responses are processed.  Static files
(`Mojo::Asset::File`) and streaming responses are left alone.
- Responses that already have a `Content-Encoding`, for example from
`$app->renderer->compress`, are not compressed again.
- Gzip, Brotli, Zstandard and identity representations have different
`ETag`s, because the tag identifies the selected representation.  A client
that switches between content codings will therefore download the page once
for each coding.
- Because the body is buffered, the plugin must not be used for
responses that are streamed with `$c->write` (server-sent events,
long-polling and so on).  `text/event-stream` is excluded by default.
- Optimising HTML rewrites the document.  Use
`optimise_content => 0` on pages where every byte matters to scripts, or
disable it per response with `$c->stash(buffer => {optimise_content => 0})`.
- The server-side cache is opt-in: a page is only stored if its action
calls ["buffer\_is\_cached"](#buffer_is_cached).  An action that forgets to call it is never
cached, and an action that calls it for a personalised page must supply a
["cache\_key"](#cache_key) that distinguishes users (the default key only includes the
`Cookie` header, not the session contents).
- The default key includes the `Cookie` header, so each session gets
its own set of entries and anonymous visitors share them.  Sites that set an
analytics cookie on every visit will get little sharing; use
`vary_by => []` for genuinely public pages, or ["cache\_key"](#cache_key).
- Single-flight is per worker by default.  Each `hypnotoad` worker
keeps its own in-flight table, so a cold entry can be built once per worker;
set ["cache\_lock"](#cache_lock) or ["cache\_lock\_dir"](#cache_lock_dir) to coalesce across workers, with a
shared cache.  A request waiting on an in-flight response is answered with
`503` if that
response fails, cannot be cached, or exceeds ["cache\_lock\_timeout"](#cache_lock_timeout), rather
than running the action a second time.
- Entries are invalidated when the application script or a template
path changes, but not when data or configuration changes.  The TTL is the
backstop for those.

## See Also

[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer), [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer), [CHI](https://metacpan.org/pod/CHI), [HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker),
[Mojolicious::Plugin](https://metacpan.org/pod/Mojolicious%3A%3APlugin), [Mojolicious::Plugin::Buffer::Lock::File](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3AFile),
[Mojolicious::Plugin::Buffer::Lock::Redis](https://metacpan.org/pod/Mojolicious%3A%3APlugin%3A%3ABuffer%3A%3ALock%3A%3ARedis)

## Author

Nigel Horne, `<njh at bandsman.co.uk>`

## License and Copyright

Copyright 2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option)
any later version.
