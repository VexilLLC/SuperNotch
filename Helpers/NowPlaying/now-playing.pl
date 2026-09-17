#!/usr/bin/perl
# Loads SuperNotch's Now Playing helper into the system perl process. See NowPlayingHelper.m.
use strict;
use warnings;
use DynaLoader;
my $path = shift @ARGV or die "usage: now-playing.pl /absolute/path/to/helper.dylib\n";
my $library = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($library, "supernotch_now_playing_stream") or die "helper entry point not found\n";
DynaLoader::dl_install_xsub("main::stream", $symbol);
stream();
