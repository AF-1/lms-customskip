#    Copyright (c) 2007 Erland Isaksson (erland_i@hotmail.com)
# 
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package Plugins::CustomSkip::BaseSettings;

use strict;
use base qw(Slim::Web::Settings);

use File::Basename;
use File::Next;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;

my $prefs = preferences('plugin.customskip');
my $log   = logger('plugin.customskip');

my $plugin; # reference to main plugin
my %subPages = ();

sub new {
	my $class = shift;
	$plugin   = shift;
	my $default = shift;

	if(!defined($default) || !$default) {
		if ($class->can('page') && $class->can('handler')) {
			if(UNIVERSAL::can("Slim::Web::Pages","addPageFunction")) {
				Slim::Web::Pages->addPageFunction($class->page, $class);
			}else {
				Slim::Web::HTTP::addPageFunction($class->page, $class);
			}
		}
	}else {
		$class->SUPER::new();
	}
	$subPages{$class->name()} = $class;
}

sub handler {
	my ($class, $client, $params) = @_;

	my %currentSubPages = ();
	for my $key (keys %subPages) {
		my $pages = $subPages{$key}->pages($client,$params);
		for my $page (@$pages) {
			$currentSubPages{$page->{'name'}} = $page->{'page'};
		}
	}
	$params->{'subpages'} = \%currentSubPages;
	$params->{'subpage'} = $class->currentPage($client,$params);
	$params->{'licensemanager'} = 1; #Plugins::CustomSkip::Plugin::isPluginsInstalled($client,'LicenseManagerPlugin');
	#my $validateRequest = Slim::Control::Request::executeRequest($client,['licensemanager','validate','application:CustomSkip']);
	$params->{'licensed'} = 1; #$validateRequest->getResult("result");
	$params->{'supportsMixers'} = $::VERSION lt '7.6';
	return $class->SUPER::handler($client, $params);
}
		
1;
