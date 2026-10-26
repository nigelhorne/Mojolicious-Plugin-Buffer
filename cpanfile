# Generated from Makefile.PL using makefilepl2cpanfile

requires 'perl', '5.16.0';

recommends 'CHI';
recommends 'Compress::Zstd';
recommends 'HTML::Packer';
recommends 'IO::Compress::Brotli';

on 'test' => sub {
	requires 'Mojo::Base';
	requires 'Test::More';
	requires 'Test::Without::Module';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
