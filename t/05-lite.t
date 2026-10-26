use strict;
use warnings;

use Test::More;
use Mojolicious::Lite;

eval { require HTML::Packer; 1 }
	or plan skip_all => 'HTML::Packer is required to test optimisation';

plugin 'Buffer' => {optimise_content => 1};

get '/' => sub {
	my $c = shift;
	$c->render(text => "<html>\n  <body>\n    <!-- a comment -->\n    <p>Hello   World</p>\n  </body>\n</html>");
};

use Test::Mojo;

my $t = Test::Mojo->new;
$t->ua->transactor->compressed(0);
$t->get_ok('/')->status_is(200);

my $body = $t->tx->res->body;
unlike($body, qr/a comment/, 'the plugin was loaded by name and optimised the response');
like($body, qr/<p>Hello World<\/p>/, 'white space was squashed');

done_testing();
