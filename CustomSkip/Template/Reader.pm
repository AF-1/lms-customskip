# 				MenuPlaylistTemplate module 
#
#    Copyright (c) 2006 Erland Isaksson (erland_i@hotmail.com)
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

use strict;
use warnings;
                   
package Plugins::CustomSkip::Template::Reader;

use Slim::Player::Client;
use File::Spec::Functions qw(:ALL);

use Slim::Utils::Prefs;
use Slim::Utils::Misc;

use File::Slurp;
use XML::Simple;

use FindBin qw($Bin);

use Cache::Cache qw( $EXPIRES_NEVER);

my $serverPrefs = preferences('server');

sub getTemplates {
	my $client = shift;
	my $mainPlugin = shift;
	my $pluginVersion = shift;
	my $cachePrefix = shift;
	my $directory = shift;
	my $extension = shift;
	my $templateType = shift;
	my $contentType = shift;
	my $resultType = shift;
	my $raw = shift;

	my $cacheName = undef;;
	my $cache = undef;
	if($cachePrefix) {
		$cacheName = $cachePrefix."/".$mainPlugin."/".$directory;
		my $cacheVersion = $pluginVersion;
		$cacheVersion =~ s/^.*\.([^\.]+)$/$1/;
		$cache = Slim::Utils::Cache->new($cachePrefix, $cacheVersion);
	}

	my @result = ();
	my @pluginDirs = ();
	if(!defined($templateType)) {
		$templateType = 'template';
	}
	if(!defined($contentType)) {
		$contentType = $templateType;
	}
	if(!defined($resultType)) {
		$resultType = $templateType;
	}
	if ($::VERSION ge '6.5') {
		@pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
	}else {
		@pluginDirs = catdir($Bin, "Plugins");
	}
	my $cacheItems = undef;
	if(defined($cache)) {
		$cacheItems = $cache->get($cacheName);
		if(!defined($cacheItems)) {
			my %noItems = ();
			my %empty = (
				'items' => \%noItems,
				'timestamp' => undef
			);
			$cacheItems = \%empty;
		}
	}
	for my $plugindir (@pluginDirs) {
		my $templateDir = catdir($plugindir,$mainPlugin,$directory);
		next unless -d $templateDir;
		my @dircontents = Slim::Utils::Misc::readDirectory($templateDir,$extension);
		for my $item (@dircontents) {
			next if -d catdir($templateDir,$item);
			my $templateId = $item;
			$templateId =~ s/\.$extension$//;
			my $timestamp = (stat (catdir($templateDir,$item)) )[9];
			if(defined($cacheItems)) {
				if(defined($cacheItems->{'items'}->{$item}) && $cacheItems->{'items'}->{$item}->{'timestamp'}>$timestamp) {
					#debugMsg("Reading $item from cache\n");
					push @result,$cacheItems->{'items'}->{$item}->{'data'};
					next;
				}
			}
			my $template = readTemplateConfiguration($templateId,catdir($templateDir,$item),$templateType,$raw);
			if(defined($template)) {
				my %templateItem = (
					'id' => $templateId,
					'type' => $resultType,
					'timestamp' => $timestamp,
					$contentType => $template
				);
				if(defined($cacheItems) && defined($timestamp)) {
					my %entry = (
						'data' => \%templateItem,
						'timestamp' => $timestamp,
					);
					delete $cacheItems->{'items'}->{$item};
					$cacheItems->{'items'}->{$item} = \%entry;
				}
				push @result,\%templateItem;
			}
		}
	}
	if(defined($cacheItems)) {
		$cacheItems->{'timestamp'} = time();
		$cache->set($cacheName,$cacheItems,$EXPIRES_NEVER);
	}
	return \@result;
}

sub readTemplateData {
	my $mainPlugin = shift;
	my $dir = shift;
	my $template = shift;
	my $extension = shift;
	#debugMsg("Loading template data for $template\n");

	if(!defined($extension)) {
		$extension = "template";
	}
	my @pluginDirs = ();
	if ($::VERSION ge '6.5') {
		@pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
	}else {
		@pluginDirs = catdir($Bin, "Plugins");
	}
	my $templateDir = undef;
	for my $plugindir (@pluginDirs) {
		next unless -d catdir($plugindir,$mainPlugin,$dir);
		$templateDir = catdir($plugindir,$mainPlugin,$dir);
	}

	my $path = catfile($templateDir, $template.".".$extension);

	# read_file from File::Slurp
	my $content = eval { read_file($path) };
	return $content;
}

sub readTemplateConfiguration {
	my $templateId = shift;
	my $path = shift;
	my $templateType = shift;
	my $raw = shift;
	#debugMsg("Loading template configuration for $templateId\n");

	# read_file from File::Slurp
	my $content = eval { read_file($path) };
	my $template = undef;
	if($raw) {
		my $parsedTemplate = parseTemplateContent($templateId,$templateType,$content);
		if($parsedTemplate) {
			$template = $content;
		}
	}else {
		$template = parseTemplateContent($templateId,$templateType,$content);
	}
	if(!$template) {
		msg("Unable to read template: $path\n");
	}
	return $template;
}

sub parseTemplateContent {
	my $id = shift;
	my $templateType = shift;
	my $content = shift;

	my $template = undef;

        if ( $content ) {
	    $content = Slim::Utils::Unicode::utf8decode($content,'utf8');
            my $xml = eval { 	XMLin($content, forcearray => ["parameter"], keyattr => []) };
            #debugMsg(Dumper($xml));
            if ($@) {
                    msg("Failed to parse $templateType configuration for $id because:\n$@\n");
            }else {
		my $include = isTemplateEnabled($xml);
		if(defined($xml->{$templateType})) {
			$xml->{$templateType}->{'id'} = $id;
		}
		if($include && defined($xml->{$templateType})) {
	                $template = $xml->{$templateType};
		}
            }
    
            # Release content
            undef $content;
        }else {
            if ($@) {
                    msg("Unable to read $templateType configuration for $id:\n$@\n");
            }else {
                msg("Unable to to read $templateType configuration for $id\n");
            }
        }
	return $template;
}

sub isTemplateEnabled {
	my $xml = shift;

	my $include = 1;
	if(defined($xml->{'minslimserverversion'})) {
		if($::VERSION lt $xml->{'minslimserverversion'}) {
			$include = 0;
		}
	}
	if(defined($xml->{'maxslimserverversion'})) {
		if($::VERSION gt $xml->{'maxslimserverversion'}) {
			$include = 0;
		}
	}
	if(defined($xml->{'database'}) && $include) {
		$include = 0;
		my $driver = $serverPrefs->get('dbsource');
		$driver =~ s/dbi:(.*?):(.*)$/$1/;
		if($driver eq $xml->{'database'}) {
			$include = 1;
		}
	}
	return $include;
}

1;

__END__
