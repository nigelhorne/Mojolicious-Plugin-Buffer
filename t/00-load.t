use strict;
use warnings;

use Test::More tests => 2;

use_ok('Mojolicious::Plugin::Buffer');

is($Mojolicious::Plugin::Buffer::VERSION, '0.02', 'Version is set');
