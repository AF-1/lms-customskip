#
# Custom Skip 3
# (c) 2021 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::CustomSkip3::Settings;

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.customskip3');
my $log = logger('plugin.customskip3');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_CUSTOMSKIP3');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/CustomSkip3/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(customskipparentfolderpath lookaheadenabled lookaheadrange lookaheaddelay jivemenuchangeprimaryfiltersetenabled));
}

1;
