# NAME

Mojolicious::Plugin::Buffer - Optimise, compress and validate Mojolicious responses

# VERSION

Version 0.07

# SYNOPSIS

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

Compression is negotiated from the `Accept-Encoding` request header, so
nothing extra is needed in your actions - a client that accepts gzip gets
gzip, everyone else gets the uncompressed response.

A server-side cache is optional and opt-in per action.  Give the plugin any
object that understands `get()`, `set()` and `remove()`, such as [CHI](https://metacpan.org/pod/CHI),
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
put a `buffer` value in the stash:

    # Don't touch this response at all (e.g. it is already compressed,
    # or the user is downloading it)
    $c->stash(buffer => 0);

    # Use different options for this response
    $c->stash(buffer => {compress_content => 0, optimise_content => 0});

# DESCRIPTION

`Mojolicious::Plugin::Buffer` is the Mojolicious equivalent of
[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer) and [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer).  It buffers the response that your
application has produced, then, before it is sent:

- optimises HTML by removing superfluous white space and comments,
minifying embedded CSS and JavaScript, and replacing links back to your own
site with relative links;
- compresses the response with whichever of Brotli, Zstandard or gzip
the client prefers and the server supports;
- adds `ETag`, `Last-Modified` and `Vary` headers, and answers
`If-None-Match` and `If-Modified-Since` conditional requests with
`304 Not Modified`;
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

# OPTIONS

All options can be given to `plugin()` and, except where noted, overridden
per request through the `buffer` stash value.

## compress\_content

Compress eligible responses, defaults to 1.  Set to 0 to only optimise (and
remember that the plugin turns off ["compress" in Mojolicious::Renderer](https://metacpan.org/pod/Mojolicious%3A%3ARenderer#compress), so a
response will then not be compressed at all).  The encodings offered to
clients are controlled by ["encodings"](#encodings).

## optimise\_content

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

## rewrite\_links

When optimising, rewrite `<a href>` and `<img src>` links that
point at the current site as absolute URLs into root-relative links, and
links to the current script with a query string into just the query string.
Defaults to 1.  Has no effect unless ["optimise\_content"](#optimise_content) is enabled.

## generate\_etag

Add an `ETag` header to `200` responses to `GET` and `HEAD` requests,
defaults to 1.  The tag is the MD5 of the response body before compression,
with a suffix for the content coding, so a gzip and an identity
representation of the same page have different tags.

## generate\_304

Answer conditional requests with `304 Not Modified` when the
`If-None-Match` (or, when it is absent, `If-Modified-Since`) header
matches, defaults to 1.  `If-None-Match` takes precedence over
`If-Modified-Since`, as required by RFC 7232.  Requires ["generate\_etag"](#generate_etag)
for the `ETag` comparison.

## last\_modified

Add a `Last-Modified` header and honour `If-Modified-Since`, defaults to 1,
which uses the newest modification time of the application script (`$0`)
and the renderer's template files and directories.  May be:

- 0 - do not generate the header
- 1 - use the newest modification time of the application script (`$0`) and
  the files and directories under the renderer's template paths
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
or a coderef there.  The template paths are scanned once per request, so for
a large tree or an application that does not use templates, an explicit
epoch or coderef is cheaper.  Database rows and other inputs are not
covered; use a coderef for pages whose freshness depends on them, or set
`last_modified => 0` and rely on ["generate\_etag"](#generate_etag) alone.

## min\_compress\_size

Do not compress bodies smaller than this many bytes, defaults to 32.
Compression is also skipped if it would not make the body smaller.

## encodings

An arrayref of the content codings to offer, in server preference order.
Defaults to `[qw(br zstd gzip)]`.  `br` is only offered if
[IO::Compress::Brotli](https://metacpan.org/pod/IO%3A%3ACompress%3A%3ABrotli) is installed and `zstd` only if [Compress::Zstd](https://metacpan.org/pod/Compress%3A%3AZstd)
is installed; gzip is always available.  Clients pick with the usual
quality values, and `identity` is used when nothing acceptable is offered.

## compressible\_types

An arrayref of media types to compress, defaults to `text/*`,
`application/json`, `application/javascript`, `application/xml`,
`application/xhtml+xml`, `image/svg+xml` and a few close relatives.
Entries may be strings (matched exactly, case-insensitively) or regular
expressions.

## excluded\_types

An arrayref of media types that are never buffered, defaults to
`text/event-stream`.  Entries may be strings or regular expressions.

## cache

An optional cache object understanding `get()`, `set()` and `remove()`,
such as a [CHI](https://metacpan.org/pod/CHI) instance.  Defaults to undef, which disables the
server-side cache.  See ["buffer\_is\_cached"](#buffer_is_cached) for the rules about what is
cached and how keys are made.

## cache\_duration

How long entries are kept in the cache, defaults to `'10 minutes'`.  It is
passed to the cache's `set()`, so for [CHI](https://metacpan.org/pod/CHI) it may be a number of seconds
or a human-readable duration.

## cache\_key

A string, or a coderef called with the controller, that overrides the
generated cache key.  Useful when several URLs should share one entry, or
when the response depends on something the default key does not cover.

## cache\_single\_flight

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
workers a cold entry can still be built up to N times.  Set
["cache\_lock\_dir"](#cache_lock_dir) to a directory shared by the workers and they will elect a
single builder across processes instead.

## cache\_lock\_timeout

How long a request may wait for another request, in this worker or another
one, to build the same entry.  Defaults to 10 seconds.  It also bounds how
long a key is considered to be in flight when the request building it never
finishes.  Fractional seconds are allowed, so `0.5` is valid.

## cache\_lock\_dir

A directory in which to keep lock files used to coalesce cache misses across
worker processes, defaults to undef, which limits single-flight to one worker.
The plugin creates the directory if necessary.

The workers must share this directory and the cache itself.  A per-worker
cache such as CHI's `Memory` driver cannot be used, because a request in one
worker cannot see the entry built in another; disable any per-worker `L1`
cache in front of a shared cache for the same reason.  Locks are non-blocking
`flock`s on one small, empty file per cache key, so they are released
automatically if a worker dies.  The files are not removed, although they are
tiny and can be deleted while the application is stopped.  Use a private
directory.

This works for [hypnotoad](https://metacpan.org/pod/hypnotoad) workers on the same host, or on a shared
filesystem that implements `flock` reliably.  It is read when the plugin is
registered, not per response.

## vary\_by

An arrayref of request header names that become part of the generated cache
key.  Defaults to `['cookie']`, which keeps one client's session from being
served to another.  Set it to `[]` for URL-only caching of pages that are
identical for every visitor, or add e.g. `'accept-language'` when the
response varies by language.  Headers listed here may also appear in the
response's `Vary` header; a response that varies on anything else is not
stored.

# METHODS

`Mojolicious::Plugin::Buffer` inherits all methods from
[Mojolicious::Plugin](https://metacpan.org/pod/Mojolicious%3A%3APlugin) and implements the following new one.  It also adds
the ["buffer\_is\_cached"](#buffer_is_cached) helper to the application.

## register

    $plugin->register(Mojolicious->new, {optimise_content => 1});Register the plugin, usually through C<$app-E<gt>plugin('Buffer', ...)>.
Croaks if an unknown option is given or an option has the wrong shape.

## buffer\_is\_cached

    get '/expensive' => sub {
        my $c = shift;
        return if $c->buffer_is_cached;
        # ... expensive work ...
        $c->render(template => 'expensive');
    };

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
workers when ["cache\_lock\_dir"](#cache_lock_dir) is set: while one request is building an
entry, later requests wait for it and replay the result instead of running
the action again.  The waiting requests are held asynchronously, so this
works for actions that themselves use the event loop.  See
["cache\_single\_flight"](#cache_single_flight) for the failure and timeout behaviour.

Calling the helper more than once is harmless, but only the first call can
hit.  To disable the cache for one response, use
`$c->stash(buffer => {cache => undef})` before calling it.

# NOTES

## Why a plugin?

[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer) replaces `STDOUT` with an in-memory buffer and does its work
in an `END` block, and [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer) buffers each FastCGI request and does
its work in `DESTROY`.  Neither trick is needed in Mojolicious: the response
already exists as an object before it is written, so the plugin can simply
hook `after_dispatch` and rewrite it.  That gives the same effect without a
source filter, without reading `$_`, and without depending on a specific
server or environment.

## Interaction with the renderer

`Mojolicious::Renderer` compresses rendered output with gzip by default
(`compress` is on and `min_compress_size` is 860 bytes).  That happens
before ["after\_dispatch" in Mojolicious](https://metacpan.org/pod/Mojolicious#after_dispatch) is emitted, which would leave this
plugin with nothing to optimise and no `ETag` to generate on any page
larger than 860 bytes.  Registering this plugin therefore calls
`$app->renderer->compress(0)`, and the plugin does the compression
instead - with gzip, Brotli or Zstandard as negotiated, and with the header
work the renderer does not do.  If you enable `$app->renderer->compress`
after loading the plugin, those responses will be skipped by the plugin.

## What is not implemented

`save_to`, which rewrites dynamic pages into static ones, is a site
generation feature rather than a response filter and is not part of this
plugin.  The server-side cache is available as the opt-in
["buffer\_is\_cached"](#buffer_is_cached) helper described above.

# CAVEATS

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
set ["cache\_lock\_dir"](#cache_lock_dir) to coalesce across workers, with a shared cache.  A
request waiting on an in-flight response is answered with `503` if that
response fails, cannot be cached, or exceeds ["cache\_lock\_timeout"](#cache_lock_timeout), rather
than running the action a second time.
- Entries are invalidated when the application script or a template
path changes, but not when data or configuration changes.  The TTL is the
backstop for those.

# SEE ALSO

[CGI::Buffer](https://metacpan.org/pod/CGI%3A%3ABuffer), [FCGI::Buffer](https://metacpan.org/pod/FCGI%3A%3ABuffer), [CHI](https://metacpan.org/pod/CHI), [HTML::Packer](https://metacpan.org/pod/HTML%3A%3APacker), [Mojolicious::Plugin](https://metacpan.org/pod/Mojolicious%3A%3APlugin)

# AUTHOR

Nigel Horne, `<njh at bandsman.co.uk>`

# LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option)
any later version.
