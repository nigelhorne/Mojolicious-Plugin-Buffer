# Generated from Makefile.PL using makefilepl2cpanfile

requires 'perl', '5.16.0';

requires 'autodie';
requires 'Carp';
requires 'Exporter';
requires 'Fcntl';
requires 'File::Path', '2.07';
requires 'File::Spec';
requires 'IPC::System::Simple';
requires 'Mojolicious', '9.00';
requires 'Params::Get', '0.17';
requires 'Params::Validate::Strict', '0.41';
requires 'Readonly', '2.00';
requires 'Return::Set', '0.05';
requires 'Scalar::Util';
requires 'Sub::Private', '0.07';
requires 'Sub::Protected', '0.03';
requires 'Time::HiRes';
requires 'version';

recommends 'CHI';
recommends 'Compress::Zstd';
recommends 'HTML::Packer';
recommends 'IO::Compress::Brotli';

on 'test' => sub {
	requires 'Digest::MD5';
	requires 'Encode';
	requires 'Errno';
	requires 'File::Temp';
	requires 'Mojo::Base';
	requires 'POSIX';
	requires 'Test::More';
	requires 'Test::Without::Module';
	recommends 'IP::Country::Fast';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
