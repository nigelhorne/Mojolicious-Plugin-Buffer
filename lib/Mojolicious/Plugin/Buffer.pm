package Mojolicious::Plugin::Buffer;

use Mojo::Base 'Mojolicious::Plugin';

use Carp qw(croak);
use Encode ();
use Mojo::Date;
use Mojo::Util qw(gzip md5_sum);
use Scalar::Util qw(blessed);

our $VERSION = '0.02';

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
	last_modified      => 0,	# 0 = off, 1 = mtime of the application script, epoch, date string or coderef
	min_compress_size  => 32,
	encodings          => [@DEFAULT_ENCODINGS],
	compressible_types => [@DEFAULT_COMPRESSIBLE_TYPES],
	excluded_types     => [@DEFAULT_EXCLUDED_TYPES],
	cache              => undef,	# a CHI-like cache object
	cache_duration     => '10 minutes',
	cache_key          => undef,	# string or coderef, overriding the generated key
	vary_by            => ['cookie'],	# request headers that become part of the cache key
);

my %KNOWN_OPTION = map { $_ => 1 } keys %DEFAULTS;

=head1 NAME

Mojolicious::Plugin::Buffer - Optimise, compress and validate Mojolicious responses

=head1 VERSION

Version 0.02

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
C<If-None-Match> and C<If-Modified-Since> conditional requests with
C<304 Not Modified>;

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

=head2 optimise_content

How hard to optimise HTML, defaults to 0 (off):

=over 4

=item 0 - leave the HTML alone

=item 1 - remove comments and superfluous white space, minify embedded CSS,
and rewrite same-site links

=item 2 - as 1, plus aggressive JavaScript minification, which can break
scripts that rely on the C<E<lt>!-- ... --E<gt>> hiding technique

=back

Optimisation only applies to C<text/html> and C<application/xhtml+xml>
responses.  It requires L<HTML::Packer>, which is checked for when the
plugin is registered.

=head2 rewrite_links

When optimising, rewrite C<E<lt>a hrefE<gt>> and C<E<lt>img srcE<gt>> links that
point at the current site as absolute URLs into root-relative links, and
links to the current script with a query string into just the query string.
Defaults to 1.  Has no effect unless L</optimise_content> is enabled.

=head2 generate_etag

Add an C<ETag> header to C<200> responses to C<GET> and C<HEAD> requests,
defaults to 1.  The tag is the MD5 of the response body before compression,
with a suffix for the content coding, so a gzip and an identity
representation of the same page have different tags.

=head2 generate_304

Answer conditional requests with C<304 Not Modified> when the
C<If-None-Match> (or, failing that, C<If-Modified-Since>) header matches,
defaults to 1.  Requires L</generate_etag> for the C<ETag> comparison.

=head2 last_modified

Add a C<Last-Modified> header and honour C<If-Modified-Since>, defaults to 0
(off).  May be:

=over 4

=item 0 - do not generate the header

=item 1 - use the modification time of the application script (C<$0>)

=item a number - a Unix epoch

=item a date string - anything L<Mojo::Date> can parse

=item a coderef - called with the controller, returns any of the above

=back

The value is ignored for responses that are not C<200> responses to
C<GET> or C<HEAD> requests.  If C<If-None-Match> is present it takes
precedence over C<If-Modified-Since>, as required by RFC 7232.

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
stored.  Entries created before the application script was last modified
are treated as misses and removed.

The stored body is the optimised but uncompressed entity, so every hit is
compressed for the requesting client, gets its own C<ETag> and can still be
answered with C<304 Not Modified>.  The cache key is a digest of the
application class, host, path, query string and the values of the headers
listed in L</vary_by>; use L</cache_key> to replace it.  Query argument order
is significant.

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

	# HTML::Packer is only needed when optimising, but fail at startup rather
	# than in the middle of a request
	if ($options{optimise_content}) {
		_module_available('HTML::Packer')
			or croak 'Mojolicious::Plugin::Buffer: optimise_content requires HTML::Packer';
	}

	# L<Mojolicious::Renderer> gzips rendered output by default, before this
	# plugin ever sees it, which would stop optimisation and ETag generation
	# from working on anything bigger than 860 bytes.  Take over that job.
	$app->renderer->compress(0);

	my $state = {options => \%options};

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

	return $check->() ? 1 : 0;
}

sub _options_for {
	my ($c, $state) = @_;

	my $override = $c->stash->{buffer};
	return (undef, 1) if defined($override) && !ref($override) && !$override;

	my $options = $state->{options};
	$options = {%$options, %$override} if ref($override) eq 'HASH';

	return ($options, 0);
}

sub _process {
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

			if (defined($etag)) {
				if (defined($if_none_match)) {
					$not_modified = _etag_matches($if_none_match, $etag);
				} elsif (defined($last_modified) &&
				  defined(my $since = $c->req->headers->if_modified_since)) {
					my $since_epoch = eval { Mojo::Date->new($since)->epoch };
					$not_modified = 1 if defined($since_epoch) && ($last_modified <= $since_epoch);
				}
			}

			if ($not_modified) {
				$c->app->log->debug("Buffer: not modified, sending 304 (ETag $etag)");
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

	my $cache = $options->{cache};
	return 0 unless $cache;
	return 0 unless _request_cacheable($c);

	# From now on a miss should populate the cache at the end of the response
	$c->stash->{'buffer.cache_checked'} = 1;

	my $key = _cache_key($c, $options);
	my $entry = eval { $cache->get($key) };
	if (my $error = $@) {
		$c->app->log->error("Buffer: cache get failed: $error");
		return 0;
	}

	unless (ref($entry) eq 'HASH' && defined($entry->{body})) {
		$c->res->headers->header('X-Cache' => 'MISS');
		return 0;
	}

	# An entry created before the application was last changed may have been
	# produced by different code, so throw it away
	my $mtime = _script_mtime($state);
	if (defined($mtime) && (($entry->{created} // 0) < $mtime)) {
		$c->app->log->debug('Buffer: discarding a cache entry older than the application');
		eval { $cache->remove($key) };
		$c->res->headers->header('X-Cache' => 'MISS');
		return 0;
	}

	$c->app->log->debug("Buffer: cache hit for $key");

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

sub _store_in_cache {
	my ($c, $options, $entity, $code) = @_;

	my $cache = $options->{cache};
	return unless $cache;
	return unless $code == 200;
	return unless _request_cacheable($c);
	return unless _response_cacheable($c->res, $options);

	my $key = _cache_key($c, $options);
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

sub _optimise {
	my ($self, $body, $c, $options) = @_;

	my $level = $options->{optimise_content} || 0;
	return $body unless $level;

	$body = _squash($body);

	if ($options->{rewrite_links}) {
		my $rewritten = _rewrite_links($body, $c);
		$body = $rewritten if defined($rewritten);
	}

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
		return _script_mtime($state);
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

=head1 NOTES

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

=item * There is no stampede protection.  Concurrent misses all run the
action and all write the same entry; CHI does not lock.

=item * Entries are invalidated when the application script's modification
time changes, but not when data or configuration changes.  The TTL is the
backstop for those.

=back

=head1 SEE ALSO

L<CGI::Buffer>, L<FCGI::Buffer>, L<CHI>, L<HTML::Packer>, L<Mojolicious::Plugin>

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option)
any later version.

=cut
