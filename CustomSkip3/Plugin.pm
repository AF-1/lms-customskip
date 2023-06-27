#
# Custom Skip 3
#
# (c) 2021 AF
#
# Based on the CustomSkip plugin by (c) 2006 Erland Isaksson
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::CustomSkip3::Plugin;

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Buttons::Home;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use File::Spec::Functions qw(:ALL);
use Class::Struct;
use Scalar::Util qw(blessed);
use File::Slurp;
use XML::Simple;
use HTML::Entities;
use Time::HiRes qw(time);
use POSIX qw(floor);
use version;

use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'CustomSkip3', 'lib');

my $prefs = preferences('plugin.customskip3');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.customskip3',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_CUSTOMSKIP3',
});

my $htmlTemplate = 'plugins/CustomSkip3/customskip_list.html';
my $filterTypes = undef;
my $filterCategories = undef;
my $filters = ();
my %currentFilter = ();
my %currentSecondaryFilter = ();
my %filterPlugins = ();
my $unclassifiedFilterTypes;
my $dplPluginName = undef;

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	if (main::WEBUI) {
		require Plugins::CustomSkip3::Settings;
		Plugins::CustomSkip3::Settings->new($class);
	}

	initPrefs();
	initFilters();
	if (scalar(keys %{$filters}) == 0) {
		my $url = $prefs->get('customskipfolderpath');

		if (-e $url) {
			my %filter = (
				'id' => 'defaultfilterset.cs.xml',
				'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_DEFAULTFILTERSET")
			);
			saveFilter(catfile($url, 'defaultfilterset.cs.xml'), \%filter);
			initFilters();
		}
	}

	Slim::Control::Request::subscribe(\&newSongCallback, [['playlist'], ['newsong']]);
	Slim::Control::Request::addDispatch(['customskip', 'changefilterset'], [1, 1, 0, \&changePrimaryFilterSet]);
	Slim::Control::Request::addDispatch(['customskip', 'setfilter', '_filterid'], [1, 0, 0, \&setCLIFilter]);
	Slim::Control::Request::addDispatch(['customskip', 'setsecondaryfilter', '_filterid'], [1, 0, 0, \&setCLISecondaryFilter]);
	Slim::Control::Request::addDispatch(['customskip', 'clearfilter', '_filterid'], [1, 0, 0, \&clearCLIFilter]);
	Slim::Control::Request::addDispatch(['customskip', 'clearsecondaryfilter', '_filterid'], [1, 0, 0, \&clearCLISecondaryFilter]);
	Slim::Control::Request::addDispatch(['customskip', 'jivecontextmenufilter'], [1, 1, 1, \&createTempJiveFilterItem]);
	registerStandardContextMenus();
}

sub postinitPlugin {
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 4, \&initFilters);
	registerJiveMenu();
	my @enabledPlugins = Slim::Utils::PluginManager->enabledPlugins();
	my $dplVersion = 0;
	for my $plugin (@enabledPlugins) {
		if ($plugin =~ /DynamicPlaylists/) {
			$dplPluginName = $plugin if int(version->parse(Slim::Utils::PluginManager->dataForPlugin($plugin)->{'version'})) > $dplVersion;
		}
	}
}

sub weight {
	return 89;
}

sub initPrefs {
	$prefs->init({
		customskipparentfolderpath => Slim::Utils::OSDetect::dirsFor('prefs'),
		lookaheadrange => 5,
		lookaheaddelay => 30
	});

	createCustomSkipFolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $customskipFolderPath = catdir($_[1], 'CustomSkip3');
		eval {
			mkdir($customskipFolderPath, 0755) unless (-d $customskipFolderPath);
		} or do {
			$log->error("Could not create CustomSkip3 folder in parent folder '$_[1]'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
			return;
		};
		$prefs->set('customskipfolderpath', $customskipFolderPath);
		return 1;
	}, 'customskipparentfolderpath');

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 15}, 'lookaheadrange');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 60}, 'lookaheaddelay');
}


### init/get filters ###

sub initFilterTypes {
	main::DEBUGLOG && $log->is_debug && $log->debug('Searching for filter types');

	my %localFilterTypes = ();

	no strict 'refs';
	my @enabledplugins = Slim::Utils::PluginManager->enabledPlugins();
	$unclassifiedFilterTypes = undef;
	for my $plugin (@enabledplugins) {
		if (UNIVERSAL::can("$plugin", "getCustomSkipFilterTypes") && UNIVERSAL::can("$plugin", "checkCustomSkipFilterType")) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Getting filter types for: $plugin");
			my $items = eval {&{"${plugin}::getCustomSkipFilterTypes"}()};
			if ($@) {
				$log->error("Error getting filter types from $plugin: $@");
			}
			for my $item (@{$items}) {
				my $id = $item->{'id'};
				if (defined ($id)) {
					$filterPlugins{$id} = "${plugin}";
					my $filter = $item;
					main::DEBUGLOG && $log->is_debug && $log->debug('Got filter type: '.$filter->{'name'});

					if (!defined ($item->{'filtercategory'})) {
						$unclassifiedFilterTypes = 'found unclassified filter types';
						$filter->{'filtercategory'} = 'zzz_undefined_filtercategory';
					}
					if ($item->{'filtercategory'} && !defined($item->{'sortname'})) {
						$filter->{'sortname'} = $item->{'filtercategory'}.'-'.$id;
					}
					my $pluginshortname = $plugin;
					$pluginshortname =~ s/^Plugins::|::Plugin+$//g;

					if ($pluginshortname eq 'CustomSkip3') {
						$pluginshortname = 'CustomSkip v3';
					}
					$filter->{'customskippluginshortname'} = $pluginshortname;

					my @allparameters = ();
					if (defined ($filter->{'parameters'})) {
						my $parameters = $filter->{'parameters'};
						@allparameters = @{$parameters};
					}
					my %percentageParameter = (
						'id' => 'customskippercentage',
						'type' => 'singlelist',
						'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_SKIPPERCENTAGE"),
						'data' => '100=100%,75=75%,50=50%,25=25%,0=0% ('.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_REMOVE").')',
						'value' => 100
					);
					push @allparameters, \%percentageParameter;
					my %retryLaterParameter = (
						'id' => 'customskipretrylater',
						'type' => 'singlelist',
						'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_RETRYLATER"),
						'data' => '0='.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICENO").',1='.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICEYES"),
						'value' => 0
					);
					push @allparameters, \%retryLaterParameter;
					my %validParameter = (
						'id' => 'customskipvalidtime',
						'type' => 'timelist',
						'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_VALID"),
						'data' => '900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK").',1209600=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEKS").',2419200=4 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEKS").',7776000=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MONTHS").',15552000=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MONTHS").',0='.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_FOREVER"),
						'value' => 0
					);
					push @allparameters, \%validParameter;
					$filter->{'customskipparameters'} = \@allparameters;
					$filter->{'customskipid'} = $id;
					$filter->{'customskipplugin'} = $plugin;
					$localFilterTypes{$id} = $filter;
				}
			}
		}
	}
	use strict 'refs';
	$filterTypes = \%localFilterTypes;
	#main::DEBUGLOG && $log->is_debug && $log->debug('filterTypes = '.Data::Dump::dump($filterTypes));
}

sub getFilters {
	my $client = shift;
	my @result = ();

	initFilters($client);
	foreach my $key (keys %{$filters}) {
		my $filter = $filters->{$key};
		main::DEBUGLOG && $log->is_debug && $log->debug('Adding filter: '.$filter->{'id'});
		push @result, $filter;
	}
	@result = sort {lc($a->{'name'}) cmp lc($b->{'name'})} @result;
	return \@result;
}

sub getAvailableFilters {
	my $client = shift;
	my @result = ();

	initFilters($client);
	foreach my $key (keys %{$filters}) {
		my $filter = $filters->{$key};
		my %item = (
			'id' => $key,
			'name' => $filter->{'name'},
			'value' => $key
		);
		push @result, \%item;
	}
	@result = sort {lc($a->{'name'}) cmp lc($b->{'name'})} @result;
	return \@result;
}

sub getFilterTypes {
	my $client = shift;
	my $params = shift;
	my @result = ();

	initFilterTypes($client);
	foreach my $key (keys %{$filterTypes}) {
		my $filterType = $filterTypes->{$key};
		push @result, $filterType;
	}
	@result = sort {lc($a->{'sortname'}) cmp lc($b->{'sortname'})} @result;
	return \@result;
}

sub initFilters {
	my $client = shift;

	my $browseDir = $prefs->get('customskipfolderpath');
	main::DEBUGLOG && $log->is_debug && $log->debug("Searching for custom skip configuration in: $browseDir");
	initFilterTypes($client);

	my %localFilters = ();
	if (!defined $browseDir || !-d $browseDir) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Skipping custom skip configuration scan - directory is undefined');
	} else {
		readFiltersFromDir($client, $browseDir, \%localFilters, $filterTypes);
	}

	for my $key (keys %localFilters) {
		my $filter = $localFilters{$key};
		removeExpiredFilterItems($filter);
	}
	$filters = \%localFilters;
}

sub removeExpiredFilterItems {
	my $filter = shift;

	my $browseDir = $prefs->get('customskipfolderpath');
	return unless defined $browseDir && -d $browseDir;

	my $filteritems = $filter->{'filter'};
	my @removeItems = ();
	my $i = 0;
	for my $filteritem (@{$filteritems}) {
		my $parameters = $filteritem->{'parameter'};
		for my $p (@{$parameters}) {
			if ($p->{'id'} eq 'customskipvalidtime') {
				my $values = $p->{'value'};
				if (defined ($values) && scalar(@{$values}) > 0 && $values->[0] > 0) {
					if ($values->[0] < time()) {
						main::DEBUGLOG && $log->is_debug && $log->debug('Remove expired filter item '.($i+1));
						push @removeItems, $i;
					}
				}
			}
		}
		$i = $i + 1;
	}
	if (scalar(@removeItems) > 0) {
		my $i = 0;
		for my $index (@removeItems) {
			splice(@{$filteritems}, $index-$i, 1);
			$i = $i - 1;
		}
		$filter->{'filter'} = $filteritems;
		if (defined $browseDir || -d $browseDir) {
			my $file = unescape($filter->{'id'});
			my $url = catfile($browseDir, $file);
			if (-e $url) {
				saveFilter($url, $filter);
			}
		}
	}
}

sub readFiltersFromDir {
	my $client = shift;
	my $browseDir = shift;
	my $localFilters = shift;
	my $filterTypes = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("Loading skip configuration from: $browseDir");

	my @dircontents = Slim::Utils::Misc::readDirectory($browseDir, 'cs.xml');
	for my $item (@dircontents) {

		next if -d catdir($browseDir, $item);

		my $path = catfile($browseDir, $item);

		# read_file from File::Slurp
		my $content = eval {read_file($path)};
		if ($content) {
			my $encoding = Slim::Utils::Unicode::encodingFromString($content);
			if ($encoding ne 'utf8') {
				$content = Slim::Utils::Unicode::latin1toUTF8($content);
				$content = Slim::Utils::Unicode::utf8on($content);
				main::DEBUGLOG && $log->is_debug && $log->debug("Loading and converting from latin1\n");
			} else {
				$content = Slim::Utils::Unicode::utf8decode($content, 'utf8');
				main::DEBUGLOG && $log->is_debug && $log->debug('Loading without conversion with encoding '.$encoding);
			}
			my $errorMsg = parseFilterContent($client, $item, $content, $localFilters, $filterTypes);
			if ($errorMsg) {
				$log->warn("CustomSkip3: Unable to open configuration file: $path\n$errorMsg");
			}
		} else {
			if ($@) {
				$log->warn("CustomSkip3: Unable to open configuration file: $path\nBecause of:\n$@");
			} else {
				$log->warn("CustomSkip3: Unable to open configuration file: $path");
			}
		}
	}
}

sub parseFilterContent {
	my $client = shift;
	my $item = shift;
	my $content = shift;
	my $localFilters = shift;
	my $filterTypes = shift;
	my $dbh = getCurrentDBH();

	my $filterId = $item;
	my $errorMsg = undef;
	if ($content) {
		$content = Slim::Utils::Unicode::utf8decode($content, 'utf8');
		my $xml = eval {XMLin($content, forcearray => ['filter', 'parameter', 'value'], keyattr => [])};
		if ($@) {
			$errorMsg = "$@";
			$log->warn("CustomSkip3: Failed to parse configuration because:\n$@");
		} else {
			my $filters = $xml->{'filter'};
			$xml->{'id'} = $filterId;
			for my $filter (@{$filters}) {
				my $filterType = $filterTypes->{$filter->{'id'}};
				if (defined ($filterType)) {
					my $displayName = $filterType->{'name'};
					my %filterParameters = ();
					my $parameters = $filter->{'parameter'};
					for my $p (@{$parameters}) {
						my $values = $p->{'value'};
						my $value = '';
						for my $v (@{$values}) {
							if ($value ne '') {
								$value .= ',';
							}
							if ($v ne '0') {
								# We don't want to enter here with '0' because then it will incorrectly be converted to ''
								my $encoding = Slim::Utils::Unicode::encodingFromString($v);
								if ($encoding ne 'utf8') {
									$v = Slim::Utils::Unicode::latin1toUTF8($v);
									$v = Slim::Utils::Unicode::utf8on($v);
									main::DEBUGLOG && $log->is_debug && $log->debug('Loading '.$p->{'id'}.' and converting from latin1');
								} else {
									$v = Slim::Utils::Unicode::utf8decode($v, 'utf8');
									main::DEBUGLOG && $log->is_debug && $log->debug('Loading '.$p->{'id'}.' without conversion with encoding '.$encoding);
								}
							}

							if ($p->{'quotevalue'}) {
								$value .= $dbh->quote(encode_entities($v));
							} else {
								$value .= encode_entities($v);
							}
						}
						$filterParameters{$p->{'id'}}=$value;
					}
					if (defined ($filterType->{'customskipparameters'})) {
						my $parameters = $filterType->{'customskipparameters'};
						for my $p (@{$parameters}) {
							if (defined ($p->{'type'}) && defined ($p->{'id'}) && defined ($p->{'name'})) {
								if (!defined ($filterParameters{$p->{'id'}})) {
									my $value = $p->{'value'};
									if (!defined ($value)) {
										$value='';
									}
									main::DEBUGLOG && $log->is_debug && $log->debug('Setting default value '.$p->{'id'}.' = '.$value);
									$filterParameters{$p->{'id'}} = $value;
								}
							}
						}
					}
					my $displayNameWeb = $displayName;
					$displayName .= ' ';
					my $displayParameters = $filterType->{'customskipparameters'};
					my $displayParametersLineWeb = '';
					for my $p (@{$displayParameters}) {
						my $displayed = 0;
						my $sepchar = HTML::Entities::decode_entities('&#x2022;');
						if (defined ($filterParameters{$p->{'id'}})) {
							if ($p->{'id'} eq 'customskippercentage') {
									$displayName .= " - ".string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_SKIPPERCENTAGE").": ".$filterParameters{$p->{'id'}}."%";
									$displayParametersLineWeb = string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_SKIPPERCENTAGE").": ".($filterParameters{$p->{'id'}} < 100 ? '&nbsp;':'').$filterParameters{$p->{'id'}}."%";
									$displayed = 1;
							} elsif ($p->{'id'} eq 'customskipretrylater') {
									$displayName .= ' - '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_RETRYLATER").': '.($filterParameters{$p->{'id'}} == 0 ? string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICENO") : string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICEYES")).' - ';
									$displayParametersLineWeb .= ' &nbsp;&nbsp;&nbsp;'.$sepchar.'&nbsp;&nbsp;&nbsp; '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_RETRYLATER").': '.($filterParameters{$p->{'id'}} == 0 ? string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICENO") : string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICEYES")).' &nbsp;&nbsp;&nbsp;'.$sepchar.'&nbsp;&nbsp;&nbsp; ';
									$displayed = 1;
							} elsif ($p->{'type'} =~ '.*timelist$') {
									my $appendedstring = $filterParameters{$p->{'id'}} > 0 ? string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_VALIDUNTIL").": ".Slim::Utils::DateTime::shortDateF($filterParameters{$p->{'id'}}).' '.Slim::Utils::DateTime::timeF($filterParameters{$p->{'id'}}) : string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_VALIDUNTIL").": ".string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_FOREVER");
									$displayName .= $appendedstring;
									$displayParametersLineWeb .= $appendedstring;
									$displayed = 1;
							} else {
								my $appendedstring = decode_entities($filterParameters{$p->{'id'}});
								if ($p->{'id'} eq 'time' || $p->{'id'} eq 'length') {
									$appendedstring = prettifyTime($appendedstring + 0);
								}
								if ($p->{'id'} eq 'url') {
									my $trackObj;
									if (Slim::Music::Info::isURL($appendedstring)) {
										$trackObj = objectForUrl($appendedstring);
									} else {
										$trackObj = objectForId('track', $appendedstring);
									}
									$appendedstring = $trackObj->name;
								}
								if ($p->{'id'} eq 'bitrate') {
									if ($appendedstring == -1) {
										$appendedstring = string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_ALLLOSSY");
									} else {
										$appendedstring = (($appendedstring+0)/1000).'kbps';
									}
								}
								if ($p->{'id'} eq 'rating') {
									$appendedstring = $appendedstring + 0;
									#my $ratingchar = ' *';
									my $ratingchar = HTML::Entities::decode_entities('&#x2605;'); # "blackstar"
									my $nobreakspace = HTML::Entities::decode_entities('&#xa0;');
									my $fractionchar = HTML::Entities::decode_entities('&#xbd;'); # "vulgar fraction one half"

									my $detecthalfstars = ($appendedstring/2)%2;
									my $ratingstars = $appendedstring/20;

									if ($detecthalfstars == 1) {
										$ratingstars = floor($ratingstars);
										$appendedstring = ($ratingchar x $ratingstars).$fractionchar.$nobreakspace;
									} else {
										$appendedstring = ($ratingchar x $ratingstars).$nobreakspace;
									}
								}
								if ($p->{'id'} eq 'virtuallibraryid') {
									my $VLID = $appendedstring;
									$appendedstring = Slim::Music::VirtualLibraries->getNameForId($appendedstring);
									if (!$appendedstring || $appendedstring eq '') {
										$appendedstring = string("PLUGIN_CUSTOMSKIP3_ERRORS_NOVLIB1").$VLID.string("PLUGIN_CUSTOMSKIP3_ERRORS_NOVLIB2");
									}
								}
								if ($p->{'id'} eq 'similarityval') {
									$appendedstring = 'Similarity: '.$appendedstring;
								}
								$displayName .= $appendedstring;
								$displayNameWeb.= ($displayNameWeb =~ ':' ? ' - ' : ': ').$appendedstring;
								$displayed = 1;
							}
						}
					}
					$filter->{'displayname'} = $displayName;
					$filter->{'displaynameweb'} = $displayNameWeb;
					$filter->{'displayparameterslineweb'} = $displayParametersLineWeb;
					$filter->{'parametervalues'} = \%filterParameters;

				} else {
					$log->warn('Skipping unknown filter type: '.$filter->{'id'});
				}
			}
			$localFilters->{$filterId} = $xml;

			# Release content
			undef $content;
		}
	} else {
		$errorMsg = 'Incorrect information in skip data';
		$log->warn('CustomSkip3: Unable to to read skip configuration');
	}
	return $errorMsg;
}


## context menus - web & jive
sub registerStandardContextMenus {
	Slim::Menu::TrackInfo->registerInfoProvider(customskip3 => (
		after => 'top',
		func => sub {
			return objectInfoHandler('track', @_);
		},
	));

	Slim::Menu::AlbumInfo->registerInfoProvider(customskip3 => (
		after => 'addalbum',
		func => sub {
			return objectInfoHandler('album', @_);
		},
	));

	Slim::Menu::ArtistInfo->registerInfoProvider(customskip3 => (
		after => 'addartist',
		func => sub {
			return objectInfoHandler('artist', @_);
		},
	));

	Slim::Menu::YearInfo->registerInfoProvider(customskip3 => (
		after => 'addyear',
		func => sub {
			return objectInfoHandler('year', @_);
		},
	));

	Slim::Menu::PlaylistInfo->registerInfoProvider(customskip3 => (
		after => 'addplaylist',
		func => sub {
			return objectInfoHandler('playlist', @_);
		},
	));

	Slim::Menu::GenreInfo->registerInfoProvider(customskip3 => (
		after => 'addgenre',
		func => sub {
			return objectInfoHandler('genre', @_);
		},
	));
}

sub objectInfoHandler {
	my ($objectType, $client, $url, $obj, $remoteMeta, $tags, $filter) = @_;
	$tags ||= {};
	my $objectName = undef;
	my $objectID = undef;
	if ($objectType eq 'genre' || $objectType eq 'artist') {
		$objectName = $obj->name;
		$objectID = $obj->id;
	} elsif ($objectType eq 'album' || $objectType eq 'playlist' || $objectType eq 'track') {
		$objectName = $obj->title;
		$objectID = $obj->id;
	} elsif ($objectType eq 'year') {
		$objectName = ($obj?$obj:$client->string('UNK'));
		$objectID = $obj;
	} else {
		return undef;
	}

	unless ($objectType eq 'artist' && Slim::Schema->variousArtistsObject->id eq $objectID) {
		my $jive = {};
		if ($tags->{menuMode}) {

			$jive->{actions} = {
				go => {
					player => 0,
					cmd => ['customskip', 'jivecontextmenufilter'],
					params => {
						menu => 1,
						useContextMenu => 1,
						'filtertype' => $objectType,
						'nextFilterItem' => 2,
						'customskip_parameter_1' => $objectID,
						'customskip_parameter_1_name' => $objectName,
					},
				},
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' -- objectID = '.$objectID.' -- objectName = '.$objectName);
		my $currentFilterSet = getCurrentFilter($client);
		if (defined $currentFilterSet) {
			$currentFilterSet = $currentFilterSet->{'id'};
		} else {
			$currentFilterSet = 'defaultfilterset.cs.xml';
		}

		return {
			type => 'redirect',
			jive => $jive,
			name => $client->string('PLUGIN_CUSTOMSKIP3'),
			favorites => 0,
			web => {
				url => 'plugins/CustomSkip3/customskip_newfilteritem.html?filter='.$currentFilterSet.'&filtertype='.$objectType.'&newfilteritem=1&customskip_parameter_1='.$objectID.'&customskip_parameter_1_name='.$objectName,
			},
		};
	}
	return undef;
}

sub createTempJiveFilterItem {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['customskip'],['jivecontextmenufilter']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		main::DEBUGLOG && $log->is_debug && $log->debug('Exiting setCLIFilter');
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		return;
	}
	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
	my $params = $request->getParamsCopy();
	my $filtertype = $request->getParam('filtertype');

	my $customskip_parameters;
	foreach my $p (1..4) {
		$customskip_parameters->{$p}->{'customskip_parameter'} = $request->getParam('customskip_parameter_'.$p);
		$customskip_parameters->{$p}->{'customskip_parameter_name'} = $request->getParam('customskip_parameter_'.$p.'_name');
	}

	my $nextFilterItem = $request->getParam('nextFilterItem');
	if ($nextFilterItem <= 4) {
		my $filterItems = {
			2 => {
				'id' => 'customskippercentage',
				'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_SKIPPERCENTAGE"),
				'values' => {
					'100%' => 100, '75%' => 75, '50%' => 50, '25%' => 25, '0% ('.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_REMOVE").')' => 0,
				},
			},
			3 => {
				'id' => 'customskipretrylater',
				'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_RETRYLATER"),
				'values' => {string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICENO") => 0, string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_CHOICEYES") => 1},
			},
			4 => {
				'id' => 'customskipvalidtime',
				'name' => string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_VALID"),
				'values' => {
					'15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS") => 900, '30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS") => 1800, '1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR") => 3600, '3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS") => 10800,'6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS") => 21600,'24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS") => 86400, '1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK") => 604800, '2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEKS") => 1209600, '4 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEKS") => 2419200, '3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MONTHS") => 7776000, '6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MONTHS") => 15552000, string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_FOREVER") => 0,
				}
			},
		};

		my $paramValues = $filterItems->{$nextFilterItem}->{'values'};
		my @sortedParamValues;
		if ($nextFilterItem == 2) {
			@sortedParamValues = sort {$paramValues->{$b} <=> $paramValues->{$a}} keys %{$paramValues};
		} else {
			@sortedParamValues = sort {$paramValues->{$a} <=> $paramValues->{$b}} keys %{$paramValues};
		}

		$request->addResult('window', {text => $filterItems->{$nextFilterItem}->{'name'}});
		my $cnt = 0;

		foreach my $valueName (@sortedParamValues) {
			my $returntext = $valueName;
			my $value = $paramValues->{$valueName};
			my $actions = {
				'go' => {
					'player' => 0,
					'cmd' => ['customskip', 'jivecontextmenufilter'],
					params => {
						'filtertype' => $filtertype,
						'nextFilterItem' => $nextFilterItem + 1,
						'customskip_parameter_1' => $customskip_parameters->{1}->{'customskip_parameter'},
						'customskip_parameter_1_name' => $customskip_parameters->{1}->{'customskip_parameter_name'},
						'customskip_parameter_2' => $customskip_parameters->{2}->{'customskip_parameter'},
						'customskip_parameter_2_name' => $customskip_parameters->{2}->{'customskip_parameter_name'},
						'customskip_parameter_3' => $customskip_parameters->{3}->{'customskip_parameter'},
						'customskip_parameter_3_name' => $customskip_parameters->{3}->{'customskip_parameter_name'},
						'customskip_parameter_4' => $customskip_parameters->{4}->{'customskip_parameter'},
						'customskip_parameter_4_name' => $customskip_parameters->{4}->{'customskip_parameter_name'},
						'customskip_parameter_'.$nextFilterItem => $value,
						'customskip_parameter_'.$nextFilterItem.'_name' => $valueName,
					}
				},
			};

			if ($nextFilterItem + 1 > 4) {
				$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'myMusic');
			}
			$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
			$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
			$request->addResultLoop('item_loop', $cnt, 'text', $returntext);
			$cnt++;
		}

		$request->addResult('offset', 0);
		$request->addResult('count', $cnt);
		$request->setStatusDone();

	} else {

		initFilters();
		my $filter = getCurrentFilter($client);
		my $browseDir = $prefs->get('customskipfolderpath');

		if (!defined $browseDir || !-d $browseDir) {
			displayErrorMessage($client, 'No custom skip directory configured');
			return;
		}
		my $file = unescape($filter->{'id'});
		my $url = catfile($browseDir, $file);

		if (!(-e $url)) {
			displayErrorMessage($client, "Invalid filename, file doesn't exist");
			return;
		}

		my $filterType = $filterTypes->{$params->{'filtertype'}};
		my %filterParameters = ();
		my $data = '';
		my @parametersToSave = ();
		if (defined ($filterType->{'customskipparameters'})) {
			my $parameters = $filterType->{'customskipparameters'};
			my $i = 1;
			for my $p (@{$parameters}) {
				if (defined ($p->{'type'}) && defined ($p->{'id'}) && defined ($p->{'name'})) {
					addValuesToFilterParameter($p);
					my $pValue;
					if ($p->{'id'} eq 'name' || $p->{'id'} eq 'title') {
						$pValue = $params->{'customskip_parameter_'.$i.'_name'};
					} elsif ($p->{'id'} eq 'customskipvalidtime') {
						if ($params->{'customskip_parameter_'.$i} > 0) {
							$pValue = time() + $params->{'customskip_parameter_'.$i};
						} else {
							$pValue = 0;
						}
					} else {
						$pValue = $params->{'customskip_parameter_'.$i};
					}
					my %savedParameter = (
						'id' => $p->{'id'},
						'value' => [$pValue]
					);
					push @parametersToSave, \%savedParameter;
					$i++;
				}
			}
		}

		my $filterItems = $filter->{'filter'};
		my %newFilterItem = (
			'id' => $filterType->{'id'},
			'parameter' => \@parametersToSave
		);
		push @{$filterItems}, \%newFilterItem;

		$filter->{'filter'} = $filterItems;
		my $error = saveFilter($url, $filter);
		if (defined ($error)) {
			displayErrorMessage($client, $error);
			return;
		}
		initFilters();
	}
}


## jive menu (change primary filter set)

sub registerJiveMenu {
	if ($prefs->get('jivemenuchangeprimaryfiltersetenabled')) {
		my $class = shift;
		my $client = shift;

		my @menuItems = (
			{
				text => Slim::Utils::Strings::string('PLUGIN_CUSTOMSKIP3_CHANGEFILTERSET'),
				weight => 999,
				id => 'customskip3changeprimaryfilterset',
				menuIcon => 'plugins/CustomSkip3/html/images/cs_icon_svg.png',
				window => {
					titleStyle => 'mymusic',
					'icon' => 'plugins/CustomSkip3/html/images/cs_icon_svg.png',
				},
				actions => {
					go => {
						cmd => ['customskip', 'changefilterset'],
					},
				},
			},
		);
		Slim::Control::Jive::registerPluginMenu(\@menuItems, 'home');
	}
}

sub changePrimaryFilterSet {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['customskip'], ['changefilterset']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		main::DEBUGLOG && $log->is_debug && $log->debug('Exiting changePrimaryFilterSet');
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		main::DEBUGLOG && $log->is_debug && $log->debug('Exiting changePrimaryFilterSet');
		return;
	}

	initFilters();
	my $localfilters = getFilters($client);
	if (!$localfilters) {
		return;
	}
	my $activePrimaryFilterSet = getCurrentFilter($client);
	my $activeSecondaryFilterSet = getCurrentSecondaryFilter($client);

	$request->addResult('window', {text => string('PLUGIN_CUSTOMSKIP3_CHANGEPRIMARYFILTERSET')});
	my $cnt = 0;

	foreach my $filter (@{$localfilters}) {
		my $returntext = '';
		if ($filter->{'id'} && $activePrimaryFilterSet->{'id'} && $filter->{'id'} eq $activePrimaryFilterSet->{'id'}) {
			$returntext = $filter->{'name'}.' ('.string("PLUGIN_CUSTOMSKIP3_PRIMARY_ACTIVE_SHORT").')';
		} elsif ($filter->{'id'} && $activeSecondaryFilterSet->{'id'} && $filter->{'id'} eq $activeSecondaryFilterSet->{'id'}) {
			$returntext = $filter->{'name'}.' ('.string("PLUGIN_CUSTOMSKIP3_SECONDARY_ACTIVE_SHORT").')';
		} else {
			$returntext = $filter->{'name'};
		}
		my $value = $filter->{'id'};
		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['customskip', 'setfilter', $value],
			},
		};

		$request->addResultLoop('item_loop', $cnt, 'style', 'itemNoAction');
		$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'refresh');
		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
		$request->addResultLoop('item_loop', $cnt, 'text', $returntext);
		$cnt++;
	}

	$request->addResultLoop('item_loop', $cnt, 'style', 'itemNoAction');
	$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'refresh');
	$request->addResultLoop('item_loop', $cnt, 'type', 'text');
	my $actions = {
		'go' => {
			'player' => 0,
			'cmd' => ['customskip', 'clearfilter'],
		},
	};
	$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
	$request->addResultLoop('item_loop', $cnt, 'text', string('PLUGIN_CUSTOMSKIP3_DISABLEALLFILTERING'));
	$cnt++;

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}



### CLI ###

sub setCLIFilter {
	main::DEBUGLOG && $log->is_debug && $log->debug('Entering setCLIFilter');
	my $request = shift;
	my $client = $request->client();

	if ($request->isNotCommand([['customskip'],['setfilter']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		return;
	}

	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();

	# get our parameters
	my $filterId = $request->getParam('_filterid');
	if (!defined $filterId || $filterId eq '') {
		$log->warn('_filterid not defined');
		$request->setStatusBadParams();
		return;
	}

	initFilters();

	if (!defined ($filters->{$filterId})) {
		$log->warn("Unknown filter $filterId");
		$request->setStatusBadParams();
		return;
	}
	my $key = $client;
	$currentFilter{$key} = $filterId;
	$prefs->client($client)->set('filter', $filterId);

	$request->addResult('filter', $filterId);
	$request->setStatusDone();
}

sub setCLISecondaryFilter {
	main::DEBUGLOG && $log->is_debug && $log->debug('Entering setCLISecondaryFilter');
	my $request = shift;
	my $client = $request->client();

	if ($request->isNotCommand([['customskip'],['setsecondaryfilter']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		return;
	}

	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();

	# get our parameters
	my $filterId = $request->getParam('_filterid');
	if (!defined $filterId || $filterId eq '') {
		$log->warn('_filterid not defined');
		$request->setStatusBadParams();
		return;
	}

	initFilters();

	if (!defined ($filters->{$filterId})) {
		$log->warn("Unknown filter $filterId");
		$request->setStatusBadParams();
		return;
	}
	my $key = $client;
	$currentSecondaryFilter{$key} = $filterId;

	$request->addResult('filter', $filterId);
	$request->setStatusDone();
}

sub clearCLIFilter {
	main::DEBUGLOG && $log->is_debug && $log->debug('Entering clearCLIFilter');
	my $request = shift;
	my $client = $request->client();

	if ($request->isNotCommand([['customskip'],['clearfilter']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		return;
	}

	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
	my $key = $client;

	$currentFilter{$key} = undef;
	$prefs->client($client)->set('filter', 0);
	$currentSecondaryFilter{$key} = undef;

	$request->setStatusDone();
}

sub clearCLISecondaryFilter {
	main::DEBUGLOG && $log->is_debug && $log->debug('Entering clearCLISecondaryFilter');
	my $request = shift;
	my $client = $request->client();

	if ($request->isNotCommand([['customskip'],['clearsecondaryfilter']])) {
		$log->warn('Incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('Client required');
		$request->setStatusNeedsClient();
		return;
	}
	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();

	my $key = $client;
	$currentSecondaryFilter{$key} = undef;

	$request->setStatusDone();
}

sub executePlayListFilter {
	my $client = shift;
	my $filter = shift;
	my $track = shift;
	my $lookaheadonly = shift;

	if (!defined($filter) || $filter->{'name'} eq 'Custom Skip') {
		my $filter = getCurrentFilter($client);
		my $secondaryFilter = getCurrentSecondaryFilter($client);
		my $skippercentage = 0;
		my $retrylater = undef;

		# check if primary filter set is limited to DPL
		unless (!$dplPluginName) {
			my $dplonly = $filter->{'dplonly'};
			my $dplActive = $dplPluginName->disableDSTM($client);
			if ($dplonly && !$dplActive) {
				main::INFOLOG && $log->is_info && $log->info('Currently active filter set is DPL-only but DPL is not active. Not executing.');
				$filter = undef;
				return 1;
			}
		}

		# stop if skipping exception applies
		my $excMinRating = $filter->{'excminrating'};
		if ($excMinRating && $excMinRating > 0) {
			my $trackRating = $track->rating || 0;
			return 1 if ($trackRating >= $excMinRating);
		}

		my $excFav = $filter->{'excfav'};
		if ($excFav) {
			return 1 if Slim::Utils::Favorites->new($client)->findUrl($track->url);
		}

		if (defined($filter) || defined($secondaryFilter)) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Using primary filter: '.Data::Dump::dump($filter->{'name'})) if defined($filter);
			main::DEBUGLOG && $log->is_debug && $log->debug('Using secondary filter: '.Data::Dump::dump($secondaryFilter->{'name'})) if defined($secondaryFilter);
			my @filteritems = ();
			if (defined($filter)) {
				removeExpiredFilterItems($filter);
				my $primaryfilteritems = $filter->{'filter'};
				if (defined($primaryfilteritems) && ref($primaryfilteritems) eq 'ARRAY') {
					push @filteritems, @{$primaryfilteritems};
				}
			}
			if (defined($secondaryFilter)) {
				removeExpiredFilterItems($secondaryFilter);
				my $secondaryfilteritems = $secondaryFilter->{'filter'};
				if (defined($secondaryfilteritems) && ref($secondaryfilteritems) eq 'ARRAY') {
					push @filteritems, @{$secondaryfilteritems};
				}
			}

			for my $filteritem (@filteritems) {
				next unless $skippercentage < 100;

				my $id = $filteritem->{'id'};
				my $plugin = $filterPlugins{$id};
				main::DEBUGLOG && $log->is_debug && $log->debug("Calling: $plugin for ".$filteritem->{'id'}." with: ".$track->url);
				no strict 'refs';
				main::DEBUGLOG && $log->is_debug && $log->debug("Calling: $plugin :: checkCustomSkipFilterType");
				my $match = eval {&{"${plugin}::checkCustomSkipFilterType"}($client, $filteritem, $track, $lookaheadonly)};
				if ($@) {
					$log->error("Error filtering tracks with $plugin: $@");
				}
				use strict 'refs';
				if ($match) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Filter '.$filteritem->{'id'}.' matched');
					my $parameters = $filteritem->{'parameter'};
					for my $p (@{$parameters}) {
						if($p->{'id'} eq 'customskippercentage') {
							my $values = $p->{'value'};
							if (defined($values) && scalar(@{$values}) > 0) {
								if($values->[0] >= $skippercentage) {
									$skippercentage = $values->[0];
									main::DEBUGLOG && $log->is_debug && $log->debug('Use skip percentage '.$skippercentage.'%');
								}
							}
						}
						if($p->{'id'} eq 'customskipretrylater') {
							my $values = $p->{'value'};
							if (defined($values) && scalar(@{$values}) > 0) {
								if(!defined($retrylater)) {
									$retrylater = $values->[0];
								}
							}
						}
					}
				}
			}
		}
		if (!defined($retrylater)) {
			$retrylater = 0;
		}
		if ($skippercentage > 0) {
			my $rnd = int rand (99);
			if($skippercentage < $rnd) {
				return 1;
			} else {
				if ($retrylater) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Skip track "'.$track->title.'"now, retry later');
					return -1;
				} else {
					main::DEBUGLOG && $log->is_debug && $log->debug('Skip track: '.$track->title);
					return 0;
				}
			}
		} else {
			return 1;
		}
	}
	return 1;
}

# common
sub newSongCallback {
	my $request = shift;
	my $client = undef;
	my $command = undef;

	$client = $request->client();
	Slim::Utils::Timers::killTimers($client, \&lookAheadFiltering);
	my $masterClient = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
	if (defined ($client) && $client->id eq $masterClient->id && $request->getRequest(0) eq 'playlist') {
		$command = $request->getRequest(1);
		my $track = $::VERSION lt '8.2' ? Slim::Player::Playlist::song($client) : Slim::Player::Playlist::track($client);

		if (defined $track && ref($track) eq 'Slim::Schema::Track') {
			main::DEBUGLOG && $log->is_debug && $log->debug('Received newsong for '.$track->url);
			my $keep = 1;
			$keep = executePlayListFilter($client, undef, $track, 0);
			if (!$keep) {
				$client->execute(['playlist', 'deleteitem', $track->url]);
				main::DEBUGLOG && $log->is_debug && $log->debug('Removing song from client playlist');
			} else {
				if ($prefs->get('lookaheadenabled')) {
					Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $prefs->get('lookaheaddelay'), \&lookAheadFiltering);
				}
			}
		}
	}
}

sub lookAheadFiltering {
	main::DEBUGLOG && $log->is_debug && $log->debug('Starting look-ahead filtering');
	my $client = shift;
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	my $clientPlaylistLength = Slim::Player::Playlist::count($client);
	my $songsRemaining = $clientPlaylistLength - $songIndex - 1;
	if ($songsRemaining < 2) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Number of remaining tracks in client playlist < 2. Not filtering');
		return;
	}
	my $lookAheadRange = $prefs->get('lookaheadrange');
	if ($lookAheadRange > $songsRemaining) {
		$lookAheadRange = $songsRemaining;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('songIndex = '.$songIndex.' -- clientPlaylistLength = '.$clientPlaylistLength.' -- lookAheadRange = '.$lookAheadRange.' -- songsRemaining: '.$songsRemaining);
	my $tracksToRemove = ();
	eval {
		foreach my $index (($songIndex + 1)..($songIndex + $lookAheadRange)) {
			my $thisTrack = $::VERSION lt '8.2' ? Slim::Player::Playlist::song($client, $index) : Slim::Player::Playlist::track($client, $index);
			if (defined $thisTrack && ref($thisTrack) eq 'Slim::Schema::Track') {
				my $result = 0;
				my $keep = 1;
				if (!$result) {
					$keep = executePlayListFilter($client, undef, $thisTrack, 1);
					main::DEBUGLOG && $log->is_debug && $log->debug('Will remove song with client playlist index '.$index.' and URL '.$thisTrack->url) if (!$keep);
				}
				if (!$keep) {
					$tracksToRemove->{$index} = $thisTrack;
				}
			}
		}
	};
	if ($@) {
		$log->warn('Look-ahead filtering got error: '.$@);
	}

	my $noOfTracksToRemove = scalar keys (%{$tracksToRemove});
	if ($noOfTracksToRemove > 0) {
		if ($clientPlaylistLength - $songIndex - $noOfTracksToRemove - 1 < 1) {
			my $lastTrack = (sort keys %{$tracksToRemove})[-1];
			delete $tracksToRemove->{$lastTrack};
			main::DEBUGLOG && $log->is_debug && $log->debug('number of tracks to delete after correction: '.scalar keys (%{$tracksToRemove}));
			main::DEBUGLOG && $log->is_debug && $log->debug('Will leave 1 track in playlist');
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('Removing songs from client playlist');
		if (scalar keys (%{$tracksToRemove}) > 0) {
			foreach my $indexPos (sort keys %{$tracksToRemove}) {
				my $thisTrack = $tracksToRemove->{$indexPos};
				$client->execute(['playlist', 'deleteitem', $thisTrack->url]);
			}
		}
	}
}

sub getCurrentFilter {
	my $client = shift;
	if (defined ($client)) {
		$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
		if (!$filters) {
			initFilterTypes();
			initFilters();
		}
		my $key = $client;
		if (defined ($currentFilter{$key})) {
			return $filters->{$currentFilter{$key}};
		} else {
			my $filter = $prefs->client($client)->get('filter');
			if (defined ($filter) && defined ($filters->{$filter})) {
				$currentFilter{$key} = $filter;
				return $filters->{$filter};
			} else {
				if (scalar(keys %{$filters}) == 1 && defined ($filters->{'defaultfilterset.cs.xml'})) {
					my $filteritems = $filters->{'defaultfilterset.cs.xml'}->{'filter'};
					if (!defined ($filteritems) || scalar(@{$filteritems}) == 0) {
						$currentFilter{$key} = 'defaultfilterset.cs.xml';
						$prefs->client($client)->set('filter', 'defaultfilterset.cs.xml');
					}
				}
			}
		}
	}
	return undef;
}

sub getCurrentSecondaryFilter {
	my $client = shift;
	if (defined ($client)) {
		$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
		if (!$filters) {
			initFilterTypes();
			initFilters();
		}
		my $key = $client;
		if (defined ($currentSecondaryFilter{$key})) {
			return $filters->{$currentSecondaryFilter{$key}};
		}
	}
	return undef;
}


#### web pages ####

sub webPages {
	my $class = shift;

	my %pages = (
		'customskip_list\.html' => \&handleWebList,
		'customskip_selectfilter\.html' => \&handleWebSelectFilter,
		'customskip_disablefilter\.html' => \&handleWebDisableFilter,
		'customskip_newfilter\.html' => \&handleWebNewFilter,
		'customskip_savenewfilter\.html' => \&handleWebSaveNewFilter,
		'customskip_savefilter\.html' => \&handleWebSaveFilter,
		'customskip_newfilteritemtypes\.html' => \&handleWebNewFilterItemTypes,
		'customskip_newfilteritem\.html' => \&handleWebNewFilterItem,
		'customskip_savefilteritem\.html' => \&handleWebSaveFilterItem,
		'customskip_editfilter\.html' => \&handleWebEditFilter,
		'customskip_deletefilter\.html' => \&handleWebDeleteFilter,
		'customskip_editfilteritem\.html' => \&handleWebEditFilterItem,
		'customskip_deletefilteritem\.html' => \&handleWebDeleteFilterItem,
	);

	my $value = $htmlTemplate;

	for my $page (keys %pages) {
		Slim::Web::Pages->addPageFunction($page, $pages{$page});
	}

	Slim::Web::Pages->addPageLinks('plugins', {'PLUGIN_CUSTOMSKIP3' => $value});
}

sub handleWebList {
	my ($client, $params) = @_;

	$params->{'pluginCustomSkip3Filters'} = getFilters($client);
	$params->{'pluginCustomSkip3ActiveFilter'} = getCurrentFilter($client);
	$params->{'pluginCustomSkip3ActiveSecondaryFilter'} = getCurrentSecondaryFilter($client);
	$params->{'pluginCustomSkip3ClientName'} = $client->name if $client;
	return Slim::Web::HTTP::filltemplatefile($htmlTemplate, $params);
}

sub handleWebSelectFilter {
	my ($client, $params) = @_;
	initFilters();

	if (defined ($client) && defined ($params->{'filter'}) && defined ($filters->{$params->{'filter'}})) {
		$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
		my $key = $client;
		$currentFilter{$key} = $params->{'filter'};
		$prefs->client($client)->set('filter', $params->{'filter'});
		$currentSecondaryFilter{$key} = undef;
	}
	return handleWebList($client, $params);
}

sub handleWebDisableFilter {
	my ($client, $params) = @_;
	if (defined ($client)) {
		$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
		my $key = $client;
		$currentFilter{$key} = undef;
		$currentSecondaryFilter{$key} = undef;
		$prefs->client($client)->set('filter', 0);
	}
	return handleWebList($client, $params);
}

sub handleWebNewFilter {
	my ($client, $params) = @_;
	$params->{'customskipfolderpath'} = $prefs->get('customskipfolderpath');
	return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_newfilter.html', $params);
}

sub handleWebSaveNewFilter {
	my ($client, $params) = @_;

	initFilters();

	my $browseDir = $prefs->get('customskipfolderpath');

	if (!defined $browseDir || !-d $browseDir) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_NOCSDIR");
	}
	my $file = unescape($params->{'name'});
	$file =~ s/[^a-zA-Z0-9]//g;
	$file = lc $file;
	if (defined ($file) && $file ne '' && !($file =~ /^.*\..*$/)) {
		$file .='.cs.xml';
		$params->{'file'} = $file.'.cs.xml';
	}
	if (!defined ($file) || $file eq '') {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_FILENAME_EMPTY");
	}

	my $url = catfile($browseDir, $file);

	if (!defined ($params->{'pluginCustomSkip3Error'}) && -e $url) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_FILENAME_EXISTS");
	}

	my %filter = (
		'id' => $file,
		'name' => $params->{'name'},
		'dplonly' => $params->{'dplonly'},
		'excminrating' => $params->{'excminrating'},
		'excfav' => $params->{'excfav'},
	);

	if (!defined ($params->{'pluginCustomSkip3Error'})) {
		my $error = saveFilter($url, \%filter);
		if (defined ($error)) {
			$params->{'pluginCustomSkip3Error'} = $error;
		}
	}

	initFilters();
	if (defined ($params->{'pluginCustomSkip3Error'})) {
		$params->{'pluginCustomSkip3EditFilterName'} = $params->{'name'};
		return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_newfilter.html', $params);
	} else {
		$params->{'filter'} = $file;
		return handleWebNewFilterItemTypes($client, $params);
	}
}

sub handleWebSaveFilter {
	my ($client, $params) = @_;

	initFilters();

	my $browseDir = $prefs->get('customskipfolderpath');

	if (!defined $browseDir || !-d $browseDir) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_NOCSDIR");
	}
	my $file = unescape($params->{'filter'});
	my $url = catfile($browseDir, $file);

	if (!defined ($params->{'pluginCustomSkip3Error'}) && !(-e $url)) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_FILENAME_EXISTSNOT");
	}

	if (defined ($params->{'name'})) {
		my $filter = $filters->{$params->{'filter'}};
		$filter->{'name'} = $params->{'name'};
		$filter->{'dplonly'} = $params->{'dplonly'};
		$filter->{'excminrating'} = $params->{'excminrating'};
		$filter->{'excfav'} = $params->{'excfav'};
		my $error = saveFilter($url, $filter);
		if (defined ($error)) {
			$params->{'pluginCustomSkip3Error'} = $error;
		}
	}

	initFilters();
	return handleWebEditFilter($client, $params);
}

sub handleWebNewFilterItemTypes {
	my ($client, $params) = @_;
	my $categorylangstrings = {
		'songs' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_TRACKS"),
		'artists' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_ARTISTS"),
		'albums' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_ALBUMS"),
		'genres' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_GENRES"),
		'years' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_YEARS"),
		'virtual libraries' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_VLIBS"),
		'playlists' => string("PLUGIN_CUSTOMSKIP3_NEW_FILTER_TYPES_CATNAME_PLAYLISTS")
	};
	$params->{'categorylangstrings'} = $categorylangstrings;
	$params->{'pluginCustomSkip3FilterTypes'} = getFilterTypes($client, $params);
	$params->{'pluginCustomSkip3Filter'} = $filters->{$params->{'filter'}};
	$params->{'unclassifiedFilterTypes'} = $unclassifiedFilterTypes;
	return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_newfilteritemtypes.html', $params);
}

sub handleWebNewFilterItem {
	my ($client, $params) = @_;
	my $filterType = $filterTypes->{$params->{'filtertype'}};
	my $parameters = $filterType->{'customskipparameters'};

	my @parametersToSelect = ();
	for my $p (@{$parameters}) {
		if (defined ($p->{'type'}) && defined ($p->{'id'}) && defined ($p->{'name'})) {
			if (defined ($params->{'customskip_parameter_1'}) && ($p->{'type'} eq 'sqlsinglelist') &&
				(((($filterType->{'customskipid'} eq 'artist') || ($filterType->{'customskipid'} eq 'genre') || ($filterType->{'customskipid'} eq 'playlist')) && ($p->{'id'} eq 'name')) ||
				(($filterType->{'customskipid'} eq 'year') && ($p->{'id'} eq 'year')) ||
				(($filterType->{'customskipid'} eq 'album') && ($p->{'id'} eq 'title'))))
				{
				my %listValue = (
					'id' => $params->{'customskip_parameter_1'},
					'name' =>$params->{'customskip_parameter_1_name'},
					'selected' => 1
				);
				push my @listValues, \%listValue;
				$p->{'values'} = \@listValues;

			} elsif (defined ($params->{'customskip_parameter_1'}) && $p->{'type'} eq 'text' && $p->{'id'} eq 'url') {
				my $trackObj = objectForId('track',$params->{'customskip_parameter_1'});
				$p->{'value'} = $trackObj->url;
				$p->{'valuename'} = $params->{'customskip_parameter_1_name'};
			} else {
				addValuesToFilterParameter($p);
			}
			push @parametersToSelect, $p;
		}
	}

	$params->{'pluginCustomSkip3Filter'} = $filters->{$params->{'filter'}};
	$params->{'pluginCustomSkip3FilterType'} = $filterType;
	$params->{'pluginCustomSkip3FilterParameters'} = \@parametersToSelect;
	return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_editfilteritem.html', $params);
}

sub handleWebSaveFilterItem {
	my ($client, $params) = @_;

	initFilters();
	my $filter = $filters->{$params->{'filter'}};

	my $browseDir = $prefs->get('customskipfolderpath');

	if (!defined $browseDir || !-d $browseDir) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_NOCSDIR");
	}
	my $file = unescape($params->{'filter'});
	my $url = catfile($browseDir, $file);

	if (!defined ($params->{'pluginCustomSkip3Error'}) && !(-e $url)) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_FILENAME_EXISTSNOT");
	}

	saveFilterItemWeb($client, $params, $url, $filter);

	initFilters();
	if (defined ($params->{'pluginCustomSkip3Error'})) {
		return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_editfilteritem.html', $params);
	} else {
		$params->{'filter'} = $file;
		return handleWebEditFilter($client, $params);
	}
}

sub handleWebDeleteFilter {
	my ($client, $params) = @_;
	my $browseDir = $prefs->get('customskipfolderpath');
	my $file = unescape($params->{'filter'});
	my $url = catfile($browseDir, $file);
	if (defined ($browseDir) && -d $browseDir && $file && -e $url) {
		unlink($url) or do {
			$log->error('Error: unable to delete file: '.$url.": $!");
		}
	}
	initFilters();
	return handleWebList($client, $params);
}

sub handleWebEditFilter {
	my ($client, $params) = @_;

	initFilters();
	my $filterId = $params->{'filter'};
	if (defined ($filterId) && defined ($filters->{$filterId})) {
		my $filter = $filters->{$filterId};
		my $filterItems = $filter->{'filter'};
		my $dplOnly = $filter->{'dplonly'};
		my $excMinRating = $filter->{'excminrating'};
		my $excFav = $filter->{'excfav'};
		$params->{'pluginCustomSkip3FilterItems'} = $filterItems;
		$params->{'pluginCustomSkip3Filter'} = $filter;
		$params->{'pluginCustomSkip3FilterDPLonly'} = $dplOnly;
		$params->{'pluginCustomSkip3FilterExcMinRating'} = $excMinRating;
		$params->{'pluginCustomSkip3FilterExcFav'} = $excFav;

		return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_editfilter.html', $params);
	}
	return handleWebList($client, $params);
}

sub handleWebDeleteFilterItem {
	my ($client, $params) = @_;
	my $browseDir = $prefs->get('customskipfolderpath');
	if (!defined $browseDir || !-d $browseDir) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_NOCSDIR");
	}
	my $file = unescape($params->{'filter'});
	my $url = catfile($browseDir, $file);
	if (!defined ($params->{'pluginCustomSkip3Error'}) && !(-e $url)) {
		$params->{'pluginCustomSkip3Error'} = string("PLUGIN_CUSTOMSKIP3_ERRORS_FILENAME_EXISTSNOT");
	}

	my $filter = $filters->{$params->{'filter'}};
	my $filteritems = $filter->{'filter'};
	my $deleteFilterItem = $params->{'filteritem'} - 1;

	splice(@{$filteritems}, $deleteFilterItem, 1);
	$filter->{'filter'} = $filteritems;

	saveFilter($url, $filter);
	return handleWebEditFilter($client, $params);
}

sub handleWebEditFilterItem {
	my ($client, $params) = @_;

	my $filterId = $params->{'filter'};
	if (defined ($filterId) && defined ($filters->{$filterId})) {
		my $filter = $filters->{$filterId};
		my $filteritems = $filter->{'filter'};
		my $filterItem = $filteritems->[$params->{'filteritem'}-1];
		my $filterType = $filterTypes->{$filterItem->{'id'}};
		if (defined ($filterType)) {
			my %currentParameterValues = ();
			my $filterItemParameters = $filterItem->{'parameter'};
			for my $p (@{$filterItemParameters}) {
				my $values = $p->{'value'};
				my %valuesHash = ();
				for my $v (@{$values}) {
					$valuesHash{$v} = $v;
				}
				if (!%valuesHash) {
					$valuesHash{''} = '';
				}
				$currentParameterValues{$p->{'id'}} = \%valuesHash;
			}
			if (defined ($filterType->{'customskipparameters'})) {
				my $parameters = $filterType->{'customskipparameters'};
				my @parametersToSelect = ();
				for my $p (@{$parameters}) {
					if (defined ($p->{'type'}) && defined ($p->{'id'}) && defined ($p->{'name'})) {
						addValuesToFilterParameter($p, $currentParameterValues{$p->{'id'}});
						push @parametersToSelect, $p;
					}
				}
				$params->{'pluginCustomSkip3Filter'} = $filter;
				$params->{'pluginCustomSkip3FilterType'} = $filterType;
				$params->{'pluginCustomSkip3FilterParameters'} = \@parametersToSelect;
			}
			return Slim::Web::HTTP::filltemplatefile('plugins/CustomSkip3/customskip_editfilteritem.html', $params);
		}
	}
	return handleWebEditFilter($client, $params);
}

sub saveFilterItemWeb {
	my ($client, $params, $url, $filter) = @_;
	my $fh;

	if (!($params->{'pluginCustomSkip3Error'})) {
		my $filterType = $filterTypes->{$params->{'filtertype'}};
		my %filterParameters = ();
		my $data = '';
		my @parametersToSave = ();
		if (defined ($filterType->{'customskipparameters'})) {
			my $parameters = $filterType->{'customskipparameters'};
			for my $p (@{$parameters}) {
				if (defined ($p->{'type'}) && defined ($p->{'id'}) && defined ($p->{'name'})) {
					addValuesToFilterParameter($p);
					my $values = getValueOfFilterParameterWeb($params, $p, "&<>\'\"");
					if (scalar(@{$values}) > 0) {
						my $j = 0;
						for my $value (@{$values}) {
							$values->[$j] = decode_entities($value);
						}
						my %savedParameter = (
							'id' => $p->{'id'},
							'value' => $values
						);
						push @parametersToSave, \%savedParameter;
					}
				}
			}
		}
		my $filterItems = $filter->{'filter'};
		my %newFilterItem = (
			'id' => $filterType->{'id'},
			'parameter' => \@parametersToSave
		);
		if (defined ($params->{'filteritem'}) && !defined ($params->{'newfilteritem'})) {
			splice(@{$filterItems}, $params->{'filteritem'} - 1, 1, \%newFilterItem);
		} else {
			push @{$filterItems}, \%newFilterItem;
		}
		$filter->{'filter'} = $filterItems;
		my $error = saveFilter($url, $filter);
		if (defined ($error)) {
			$params->{'pluginCustomSkip3Error'} = $error;
		}
	}

	if ($params->{'pluginCustomSkip3Error'}) {
		my %parameters;
		for my $p (keys %{$params}) {
			if ($p =~ /^filterparameter_/) {
				$parameters{$p}=$params->{$p};
			}
		}
		$params->{'pluginCustomSkip3FilterParameters'} = \%parameters;
		$params->{'pluginCustomSkip3FilterType'} = $params->{'filtertype'};

		return undef;
	} else {
		return 1;
	}
}

sub saveFilter {
	my ($url, $filter) = @_;
	my $fh;

	if (!($url =~ /.*\.cs\.xml$/)) {
		return 'Filename must end with .cs.xml';
	}
	my $data = '';
	$data .= "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<customskip>\n\t<name>".encode_entities($filter->{'name'}, "&<>\'\"")."</name>\n";
	my $filterItems = $filter->{'filter'};
	my $dplonly = $filter->{'dplonly'};
	if ($dplonly) {
		$data .= "\t<dplonly>".$dplonly."</dplonly>\n";
	}
	my $exceptionMinRating = $filter->{'excminrating'};
	if ($exceptionMinRating) {
		$data .= "\t<excminrating>".$exceptionMinRating."</excminrating>\n";
	}
	my $exceptionFav = $filter->{'excfav'};
	if ($exceptionFav) {
		$data .= "\t<excfav>".$exceptionFav."</excfav>\n";
	}
	for my $filterItem (@{$filterItems}) {
		$data .= "\t<filter>\n\t\t<id>".$filterItem->{'id'}."</id>\n";
		my $parameters = $filterItem->{'parameter'};
		if (scalar(@{$parameters}) > 0) {
			for my $parameter (@{$parameters}) {
				$data .= "\t\t<parameter>\n\t\t\t<id>".$parameter->{'id'}."</id>\n";
				my $values = $parameter->{'value'};
				if (scalar(@{$values}) > 0) {
					for my $value (@{$values}) {
						$data .= "\t\t\t<value>".encode_entities($value, "&<>\'\"")."</value>\n";
					}
				}
				$data .= "\t\t</parameter>\n";
			}
		}
		$data .= "\t</filter>\n";
	}
	$data .= "</customskip>\n";

	main::DEBUGLOG && $log->is_debug && $log->debug('Opening browse configuration file: '.$url);
	open($fh, "> $url") or do {
		return 'Error saving filter';
	};
	main::DEBUGLOG && $log->is_debug && $log->debug('Writing to file: '.$url);
	print $fh $data;
	main::DEBUGLOG && $log->is_debug && $log->debug('Writing to file succeeded');
	close $fh;

	return undef;
}

sub addValuesToFilterParameter {
	my $p = shift;
	my $currentValues = shift;

	if ($p->{'type'} =~ '^sql.*') {
		my $listValues = getSQLTemplateData($p->{'data'});
		if (defined ($currentValues)) {
			for my $v (@{$listValues}) {
				if ($currentValues->{$v->{'value'}}) {
					$v->{'selected'} = 1;
				}
			}
		} elsif (defined ($p->{'value'})) {
			for my $v (@{$listValues}) {
				if ($p->{'value'} eq $v->{'value'}) {
					$v->{'selected'} = 1;
				}
			}
		}
		$p->{'values'} = $listValues;
	} elsif ($p->{'type'} =~ '.*multiplelist$' || $p->{'type'} =~ '.*singlelist$' || $p->{'type'} =~ '.*checkboxes$') {
		my @listValues = ();
		my @values = split(/,/, $p->{'data'});
		for my $value (@values){
			my @idName = split(/=/, $value);
			my %listValue = (
				'id' => $idName[0],
				'name' => $idName[1]
			);
			if (scalar(@idName) > 2) {
				$listValue{'value'} = $idName[2];
			} else {
				$listValue{'value'} = $idName[0];
			}
			push @listValues, \%listValue;
		}
		if (defined ($currentValues)) {
			for my $v (@listValues) {
				if ($currentValues->{$v->{'value'}}) {
					$v->{'selected'} = 1;
				}
			}
		} elsif (defined ($p->{'value'})) {
			for my $v (@listValues) {
				if ($p->{'value'} eq $v->{'value'}) {
					$v->{'selected'} = 1;
				}
			}
		}
		$p->{'values'} = \@listValues;
	} elsif ($p->{'type'} =~ '.*timelist$') {
		my @listValues = ();
		my @values = split(/,/, $p->{'data'});
		my $currentTime = time();
		for my $value (@values){
			my @idName = split(/=/, $value);
			my $itemTime = undef;
			my $itemName = undef;
			if ($idName[0] == 0) {
				$itemTime = 0;
				$itemName = string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_FOREVER");
			} else {
				$itemTime = $currentTime+$idName[0];
				$itemName = $idName[1].' ('.Slim::Utils::DateTime::shortDateF($itemTime).' '.Slim::Utils::DateTime::timeF($itemTime).')';
			}
			my %listValue = (
				'id' => $itemTime,
				'name' => $itemName
			);
			if ((!defined ($currentValues) || defined ($currentValues->{0})) && $p->{'value'} eq $idName[0]) {
				$listValue{'selected'} = 1;
			}
			push @listValues, \%listValue;
		}
		if (defined ($currentValues)) {
			for my $value (keys %{$currentValues}) {
				if ($value != 0) {
					my $itemTime = $value;
					my $itemName = Slim::Utils::DateTime::shortDateF($itemTime).' '.Slim::Utils::DateTime::timeF($itemTime);
					my %listValue = (
						'id' => $itemTime,
						'name' => $itemName,
						'selected' => 1
					);
					push @listValues, \%listValue;
				}
			}
		}
		$p->{'values'} = \@listValues;
	} elsif (defined ($currentValues)) {
		for my $v (keys %{$currentValues}) {
			$p->{'value'} = $v;
		}
	}
}

sub getValueOfFilterParameterWeb {
	my $params = shift;
	my $parameter = shift;
	my $encodeentities = shift;

	my $dbh = getCurrentDBH();
	if ($parameter->{'type'} =~ /.*multiplelist$/ || $parameter->{'type'} =~ /.*checkboxes$/) {
		my $selectedValues = undef;
		if ($parameter->{'type'} =~ /.*multiplelist$/) {
			$selectedValues = getMultipleListQueryParameter($params, 'filterparameter_'.$parameter->{'id'});
		} else {
			$selectedValues = getCheckBoxesQueryParameter($params, 'filterparameter_'.$parameter->{'id'});
		}
		my $values = $parameter->{'values'};
		my @result = ();
		for my $item (@{$values}) {
			if (defined ($selectedValues->{$item->{'id'}})) {
				if (defined ($encodeentities)) {
					$item->{'value'} = encode_entities($item->{'value'}, $encodeentities);
				}
				if ($parameter->{'quotevalue'}) {
					push @result, $item->{'value'};
				} else {
					push @result, $item->{'value'};
				}
			}
		}
		return \@result;
	} elsif ($parameter->{'type'} =~ /.*singlelist$/) {
		my $values = $parameter->{'values'};
		my $selectedValue = $params->{'filterparameter_'.$parameter->{'id'}};
		my @result = ();
		for my $item (@{$values}) {
			if ($selectedValue eq $item->{'id'}) {
				if (defined ($encodeentities)) {
					$item->{'value'} = encode_entities($item->{'value'}, $encodeentities);
				}
				if ($parameter->{'quotevalue'}) {
					push @result, $item->{'value'};
				} else {
					push @result, $item->{'value'};
				}
				last;
			}
		}
		return \@result;
	} elsif ($parameter->{'type'} =~ /.*timelist$/) {
		my @result = ();
		my $selectedValue = $params->{'filterparameter_'.$parameter->{'id'}};
		push @result, $selectedValue;
		return \@result;
	} else {
		my @result = ();
		if (defined ($params->{'filterparameter_'.$parameter->{'id'}}) && $params->{'filterparameter_'.$parameter->{'id'}} ne '') {
			my $value = $params->{'filterparameter_'.$parameter->{'id'}};
			if (defined ($encodeentities)) {
				$value = encode_entities($value, $encodeentities);
			}
			if ($parameter->{'quotevalue'}) {
				push @result, $value;
			} else {
				push @result, $value;
			}
		}
		return \@result;
	}
}

sub getValueOfFilterParameter {
	my $client = shift;
	my $parameter = shift;
	my $parameterNo = shift;
	my $encodeentities = shift;

	my $dbh = getCurrentDBH();
	if ($parameter->{'type'} =~ /.*multiplelist$/ || $parameter->{'type'} =~ /.*checkboxes$/) {
		my $selectedValue = undef;
		if ($parameter->{'type'} =~ /.*multiplelist$/) {
			$selectedValue = $client->modeParam('customskip_parameter_'.$parameterNo);
		} else {
			$selectedValue = $client->modeParam('customskip_parameter_'.$parameterNo);
		}

		my $values = $parameter->{'values'};
		my @result = ();
		for my $item (@{$values}) {
			if ($selectedValue eq $item->{'id'}) {
				if (defined ($encodeentities)) {
					$item->{'value'} = encode_entities($item->{'value'}, $encodeentities);
				}
				if ($parameter->{'quotevalue'}) {
					push @result, $item->{'value'};
				} else {
					push @result, $item->{'value'};
				}
			}
		}
		return \@result;

	} elsif ($parameter->{'type'} =~ /.*singlelist$/) {
		my $selectedValue = $client->modeParam('customskip_parameter_'.$parameterNo);
		my $values = $parameter->{'values'};
		my @result = ();
		for my $item (@{$values}) {
			if ($selectedValue eq $item->{'id'}) {
				if (defined ($encodeentities)) {
					$item->{'value'} = encode_entities($item->{'value'}, $encodeentities);
				}
				if ($parameter->{'quotevalue'}) {
					push @result, $item->{'value'};
				} else {
					push @result, $item->{'value'};
				}
			}
		}
		return \@result;
	} elsif ($parameter->{'type'} =~ /.*timelist$/) {
		my @result = ();
		my $selectedValue = $client->modeParam('customskip_parameter_'.$parameterNo);
		push @result, $selectedValue;
		return \@result;
	} else {
		my @result = ();
		my $selectedValue = $client->modeParam('customskip_parameter_'.$parameterNo);
		push @result, $selectedValue;
		return \@result;
	}
}

sub getMultipleListQueryParameter {
	my $params = shift;
	my $parameter = shift;

	my $query = $params->{url_query};
	my %result = ();
	if ($query) {
		foreach my $param (split /\&/, $query) {
			if ($param =~ /([^=]+)=(.*)/) {
				my $name = unescape($1);
				my $value = unescape($2);
				if ($name eq $parameter) {
					# We need to turn perl's internal
					# representation of the unescaped
					# UTF-8 string into a "real" UTF-8
					# string with the appropriate magic set.
					if ($value ne '*' && $value ne '') {
						$value = Slim::Utils::Unicode::utf8on($value);
						$value = Slim::Utils::Unicode::utf8encode_locale($value);
					}
					$result{$value} = 1;
				}
			}
		}
	}
	return \%result;
}

sub getCheckBoxesQueryParameter {
	my $params = shift;
	my $parameter = shift;

	my %result = ();
	foreach my $key (keys %{$params}) {
		my $pattern = '^'.$parameter.'_(.*)';
		if ($key =~ /$pattern/) {
			my $id = unescape($1);
			$result{$id} = 1;
		}
	}
	return \%result;
}

sub getSQLTemplateData {
	my $sqlstatements = shift;
	my @result =();
	my $dbh = getCurrentDBH();
	my $trackno = 0;
	my $sqlerrors = '';
	for my $sql (split(/[;]/, $sqlstatements)) {
		eval {
			$sql =~ s/^\s+//g;
			$sql =~ s/\s+$//g;
			my $sth = $dbh->prepare($sql);
			main::DEBUGLOG && $log->is_debug && $log->debug("Executing: $sql");
			$sth->execute() or do {
				$log->error("Error executing: $sql");
				$sql = undef;
			};

			if ($sql =~ /^SELECT+/oi) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Executing and collecting: $sql");
				my $id;
				my $name;
				my $value;
				$sth->bind_col(1, \$id);
				$sth->bind_col(2, \$name);
				$sth->bind_col(3, \$value);
				while ($sth->fetch()) {
					my %item = (
						'id' => $id,
						'name' => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
						'value' => Slim::Utils::Unicode::utf8decode($value, 'utf8')
					);
					push @result, \%item;
				}
			}
			$sth->finish();
		};
		if ($@) {
			$log->error("Database error: $DBI::errstr");
		}
	}
	return \@result;
}


### built-in filters ###

sub getCustomSkipFilterTypes {
	my @result = ();
	my %track = (
		'id' => 'track',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACK_NAME"),
		'sortname' => 'songs-01',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACK_DESC"),
		'parameters' => [
			{
				'id' => 'url',
				'type' => 'text',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACK_PARAM_NAME")
			}
		]
	);
	push @result, \%track;

	my %artist = (
		'id' => 'artist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTIST_NAME"),
		'sortname' => 'artists-01',
		'filtercategory' => 'artists',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTIST_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTIST_PARAM_NAME"),
				'data' => 'select id,name,name from contributors order by namesort'
			}
		]
	);
	push @result, \%artist;

	my %notartist = (
		'id' => 'notartist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTARTIST_NAME"),
		'sortname' => 'artists-02',
		'filtercategory' => 'artists',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTARTIST_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTARTIST_PARAM_NAME"),
				'data' => 'select id,name,name from contributors order by namesort'
			}
		]
	);
	push @result, \%notartist;

	my %recentlyplayedartists = (
		'id' => 'recentlyplayedartist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTISTSRECENTLYPLAYED_NAME"),
		'sortname' => 'artists-03',
		'filtercategory' => 'artists',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTISTSRECENTLYPLAYED_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ARTISTSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 600
			}
		]
	);
	push @result, \%recentlyplayedartists;

	my %album = (
		'id' => 'album',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUM_NAME"),
		'sortname' => 'albums-01',
		'filtercategory' => 'albums',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUM_DESC"),
		'parameters' => [
			{
				'id' => 'title',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUM_PARAM_NAME"),
				'data' => 'select id,title,title from albums order by titlesort'
			}
		]
	);
	push @result, \%album;

	my %notalbum = (
		'id' => 'notalbum',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTALBUM_NAME"),
		'sortname' => 'albums-02',
		'filtercategory' => 'albums',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTALBUM_DESC"),
		'parameters' => [
			{
				'id' => 'title',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTALBUM_PARAM_NAME"),
				'data' => 'select id,title,title from albums order by titlesort'
			}
		]
	);
	push @result, \%notalbum;

	my %recentlyplayedalbums = (
		'id' => 'recentlyplayedalbum',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUMSRECENTLYPLAYED_NAME"),
		'sortname' => 'albums-03',
		'filtercategory' => 'albums',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUMSRECENTLYPLAYED_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_ALBUMSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 600
			}
		]
	);
	push @result, \%recentlyplayedalbums;

	my %genre = (
		'id' => 'genre',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_GENRE_NAME"),
		'sortname' => 'genres-01',
		'filtercategory' => 'genres',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_GENRE_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_GENRE_PARAM_NAME"),
				'data' => 'select id,name,name from genres order by namesort'
			}
		]
	);
	push @result, \%genre;

	my %notgenre = (
		'id' => 'notgenre',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTGENRE_NAME"),
		'sortname' => 'genres-02',
		'filtercategory' => 'genres',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTGENRE_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTGENRE_PARAM_NAME"),
				'data' => 'select id,name,name from genres order by namesort'
			}
		]
	);
	push @result, \%notgenre;

	my %playlist = (
		'id' => 'playlist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_PLAYLIST_NAME"),
		'sortname' => 'playlists-01',
		'filtercategory' => 'playlists',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_PLAYLIST_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_PLAYLIST_PARAM_NAME"),
				'data' => "select playlist_track.playlist,tracks.title,tracks.title from tracks, playlist_track where tracks.id=playlist_track.playlist and tracks.content_type != 'cpl' group by playlist_track.playlist order by titlesort"
			}
		]
	);
	push @result, \%playlist;

	my %notplaylist = (
		'id' => 'notplaylist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTPLAYLIST_NAME"),
		'sortname' => 'playlists-02',
		'filtercategory' => 'playlists',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTPLAYLIST_DESC"),
		'parameters' => [
			{
				'id' => 'name',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTPLAYLIST_PARAM_NAME"),
				'data' => "select playlist_track.playlist,tracks.title,tracks.title from tracks, playlist_track where tracks.id=playlist_track.playlist and tracks.content_type != 'cpl' group by playlist_track.playlist order by titlesort"
			}
		]
	);
	push @result, \%notplaylist;

	my %year = (
		'id' => 'year',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_YEAR_NAME"),
		'sortname' => 'years-01',
		'filtercategory' => 'years',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_YEAR_DESC"),
		'parameters' => [
			{
				'id' => 'year',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_YEAR_PARAM_NAME"),
				'data' => 'select year,year,year from tracks where year is not null and year != 0 group by year order by year desc'
			}
		]
	);
	push @result, \%year;

	my %maxyear = (
		'id' => 'maxyear',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MAXYEAR_NAME"),
		'sortname' => 'years-02',
		'filtercategory' => 'years',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MAXYEAR_DESC"),
		'parameters' => [
			{
				'id' => 'year',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MAXYEAR_PARAM_NAME"),
				'data' => 'select year,year,year from tracks where year is not null and year != 0 group by year order by year desc'
			}
		]
	);
	push @result, \%maxyear;

	my %minyear = (
		'id' => 'minyear',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MINYEAR_NAME"),
		'sortname' => 'years-03',
		'filtercategory' => 'years',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MINYEAR_DESC"),
		'parameters' => [
			{
				'id' => 'year',
				'type' => 'sqlsinglelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_MINYEAR_PARAM_NAME"),
				'data' => 'select year,year,year from tracks where year is not null and year != 0 group by year order by year desc'
			}
		]
	);
	push @result, \%minyear;

	my %shortsongs = (
		'id' => 'shortsongs',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSSHORT_NAME"),
		'sortname' => 'songs-02',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSSHORT_DESC"),
		'parameters' => [
			{
				'id' => 'length',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSSHORT_PARAM_NAME"),
				'data' => '5=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SECS").',10=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SECS").',15=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SECS").',30=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SECS").',60=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MIN").',90=1.5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',120=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS"),
				'value' => 90
			}
		]
	);
	push @result, \%shortsongs;

	my %longsongs = (
		'id' => 'longsongs',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSLONG_NAME"),
		'sortname' => 'songs-03',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSLONG_DESC"),
		'parameters' => [
			{
				'id' => 'length',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSLONG_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR"),
				'value' => 900
			}
		]
	);
	push @result, \%longsongs;

	my %commentkeyword = (
		'id' => 'commentkeyword',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDCOMMENT_NAME"),
		'sortname' => 'songs-04',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDCOMMENT_DESC"),
		'parameters' => [
			{
				'id' => 'keyword',
				'type' => 'text',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDCOMMENT_PARAM_NAME")
			}
		]
	);
	push @result, \%commentkeyword;

	my %tracktitlekeyword = (
		'id' => 'tracktitlekeyword',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDTRACKTITLE_NAME"),
		'sortname' => 'songs-05',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDTRACKTITLE_DESC"),
		'parameters' => [
			{
				'id' => 'titlekeyword',
				'type' => 'text',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_KEYWORDTRACKTITLE_PARAM_NAME")
			}
		]
	);
	push @result, \%tracktitlekeyword;

	my %rated = (
		'id' => 'rated',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATED_NAME"),
		'sortname' => 'songs-07',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATED_DESC"),
		'filtercategory' => 'songs'
	);
	push @result, \%rated;

	my %notrated = (
		'id' => 'notrated',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_NOTRATED_NAME"),
		'sortname' => 'songs-08',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_NOTRATED_DESC")
	);
	push @result, \%notrated;

	my $ratingchar = HTML::Entities::decode_entities('&#x2605;'); # "blackstar"
	my $nobreakspace = HTML::Entities::decode_entities('&#xa0;');
	my $fractionchar = HTML::Entities::decode_entities('&#xbd;');
	my %ratedlow = (
		'id' => 'ratedlow',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDLOW_NAME"),
		'sortname' => 'songs-09',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDLOW_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'rating',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDLOW_PARAM_NAME"),
				'data' => '10='.$fractionchar.',20='.$ratingchar.',30='.$ratingchar.$fractionchar.',40='.$ratingchar.$ratingchar.',50='.$ratingchar.$ratingchar.$fractionchar.',60='.$ratingchar.$ratingchar.$ratingchar.',70='.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',80='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.',90='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',100='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$ratingchar,
				'value' => 60
			}
		]
	);
	push @result, \%ratedlow;

	my %ratedhigh = (
		'id' => 'ratedhigh',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDHIGH_NAME"),
		'sortname' => 'songs-10',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDHIGH_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'rating',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_RATEDHIGH_PARAM_NAME"),
				'data' => '10='.$fractionchar.',20='.$ratingchar.',30='.$ratingchar.$fractionchar.',40='.$ratingchar.$ratingchar.',50='.$ratingchar.$ratingchar.$fractionchar.',60='.$ratingchar.$ratingchar.$ratingchar.',70='.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',80='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.',90='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',100='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$ratingchar,
				'value' => 60
			}
		]
	);
	push @result, \%ratedhigh;

	my %exactroundedrating = (
		'id' => 'exactroundedrating',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_EXACTROUNDEDRATING_NAME"),
		'sortname' => 'songs-11',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_EXACTROUNDEDRATING_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'rating',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKS_EXACTROUNDEDRATING_PARAM_NAME"),
				'data' => '10='.$fractionchar.',20='.$ratingchar.',30='.$ratingchar.$fractionchar.',40='.$ratingchar.$ratingchar.',50='.$ratingchar.$ratingchar.$fractionchar.',60='.$ratingchar.$ratingchar.$ratingchar.',70='.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',80='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.',90='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$fractionchar.',100='.$ratingchar.$ratingchar.$ratingchar.$ratingchar.$ratingchar,
				'value' => 60
			}
		]
	);
	push @result, \%exactroundedrating;

	my %lossy = (
		'id' => 'lossy',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSY_NAME"),
		'sortname' => 'songs-12',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSY_DESC"),
		'parameters' => [
			{
				'id' => 'bitrate',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSY_PARAM_NAME"),
				'data' => '64000=64kbps,96000=96kbps,128000=128kbps,160000=160kbps,192000=192kbps,256000=256kbps,320000=320kbps,-1='.string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSY_ALL"),
				'value' => 64000
			}
		]
	);
	push @result, \%lossy;

	my %lossless = (
		'id' => 'lossless',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSLESS_NAME"),
		'sortname' => 'songs-13',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_LOSSLESS_DESC")
	);
	push @result, \%lossless;

	my %recentlyplayedtracks = (
		'id' => 'recentlyplayedtrack',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYED_NAME"),
		'sortname' => 'songs-14',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYED_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 3600
			}
		]
	);
	push @result, \%recentlyplayedtracks;

	my %recentlyplayedsimilartracksbysameartist = (
		'id' => 'recentlyplayedsimilartrackbysameartist',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYEDSIMILARBYSAMEARTIST_NAME"),
		'sortname' => 'songs-15',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYEDSIMILARBYSAMEARTIST_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 3600
			},
			{
				'id' => 'similarityval',
				'type' => 'numberrange',
				'minvalue' => 50,
				'maxvalue' => 100,
				'stepvalue' => 1,
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKTITLESIMILARITYVAL_PARAM_NAME"),
				'value' => 85
			},
		]
	);
	push @result, \%recentlyplayedsimilartracksbysameartist;

	my %onlinelibrarytrack = (
		'id' => 'onlinelibrarytrack',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSONLINE_NAME"),
		'sortname' => 'songs-16',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSONLINE_DESC")
	);
	push @result, \%onlinelibrarytrack;

	my %localfilelibrarytrack = (
		'id' => 'localfilelibrarytrack',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSLOCAL_NAME"),
		'sortname' => 'songs-17',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSLOCAL_DESC")
	);
	push @result, \%localfilelibrarytrack;

	my %zapped = (
		'id' => 'zapped',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSZAPPED_NAME"),
		'sortname' => 'songs-99',
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSZAPPED_DESC")
	);
	push @result, \%zapped;

	my %virtuallibrary = (
		'id' => 'virtuallibrary',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_VLIB_NAME"),
		'sortname' => 'vlib-01',
		'filtercategory' => 'virtual libraries',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_VLIB_DESC"),
		'parameters' => [
			{
				'id' => 'virtuallibraryid',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_VLIB_PARAM_NAME"),
				'data' => getVirtualLibraries(),
				'value' => undef
			}
		]
	);
	push @result, \%virtuallibrary;

	my %notvirtuallibrary = (
		'id' => 'notvirtuallibrary',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTVLIB_NAME"),
		'sortname' => 'vlib-02',
		'filtercategory' => 'virtual libraries',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTVLIB_DESC"),
		'parameters' => [
			{
				'id' => 'virtuallibraryid',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTVLIB_PARAM_NAME"),
				'data' => getVirtualLibraries(),
				'value' => undef
			}
		]
	);
	push @result, \%notvirtuallibrary;

	my %notactivevirtuallibrary = (
		'id' => 'notactivevirtuallibrary',
		'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTACTIVEVLIB_NAME"),
		'sortname' => 'vlib-03',
		'filtercategory' => 'virtual libraries',
		'description' => string("PLUGIN_CUSTOMSKIP3_FILTERS_NOTACTIVEVLIB_DESC")
	);
	push @result, \%notactivevirtuallibrary;

	return \@result;
}

sub checkCustomSkipFilterType {
	my $client = shift;
	my $filter = shift;
	my $track = shift;
	my $lookaheadonly = shift;

	my $parameters = $filter->{'parameter'};
	if ($filter->{'id'} eq 'track') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'url') {
				my $urls = $parameter->{'value'};
				my $url = $urls->[0] if (defined ($urls) && scalar(@{$urls}) > 0);
				if ($track->url eq $url) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'shortsongs') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'length') {
				my $lengths = $parameter->{'value'};
				my $length = $lengths->[0] if (defined ($lengths) && scalar(@{$lengths}) > 0);

				if ($track->secs <= $length) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'longsongs') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'length') {
				my $lengths = $parameter->{'value'};
				my $length = $lengths->[0] if (defined ($lengths) && scalar(@{$lengths}) > 0);

				if ($track->secs >= $length) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'lossy') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'bitrate') {
				unless ($track->remote) {
					my $bitrates = $parameter->{'value'};
					my $bitrate = $bitrates->[0] if (defined ($bitrates) && scalar(@{$bitrates}) > 0);

					if (($bitrate eq -1 && !$track->lossless) || ($bitrate && $track->bitrate <= $bitrate)) {
						return 1;
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'lossless') {
		if ($track->lossless) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'rated') {
		my $trackRating = $track->rating;
		if (defined $trackRating && $trackRating > 0) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'notrated') {
		my $trackRating = $track->rating;
		if (!$trackRating) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'ratedlow') {
		my $trackRating = $track->rating;
			for my $parameter (@{$parameters}) {
				if ($parameter->{'id'} eq 'rating') {
					my $ratings = $parameter->{'value'};
					my $rating = $ratings->[0] if (defined ($ratings) && scalar(@{$ratings}) > 0);
					if (defined $trackRating && $trackRating < $rating) {
						return 1;
					}
					last;
				}
			}
	} elsif ($filter->{'id'} eq 'ratedhigh') {
		my $trackRating = $track->rating;
			for my $parameter (@{$parameters}) {
				if ($parameter->{'id'} eq 'rating') {
					my $ratings = $parameter->{'value'};
					my $rating = $ratings->[0] if (defined ($ratings) && scalar(@{$ratings}) > 0);
					if (defined $trackRating && $trackRating > $rating) {
						return 1;
					}
					last;
				}
			}
	} elsif ($filter->{'id'} eq 'exactroundedrating') {
		my $trackRating = $track->rating;
			for my $parameter (@{$parameters}) {
				if ($parameter->{'id'} eq 'rating') {
					my $ratings = $parameter->{'value'};
					my $rating = $ratings->[0] if (defined ($ratings) && scalar(@{$ratings}) > 0);
					if ($trackRating) {
						my $roundedRating = floor(($trackRating + 5) / 10) * 10;
						return 1 if $rating == $roundedRating;
					}
					last;
				}
			}
	} elsif ($filter->{'id'} eq 'commentkeyword') {
		my $thiscomment = $track->comment;
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'keyword') {
				my $keywords = $parameter->{'value'};
				my $keyword = $keywords->[0] if (defined ($keywords) && scalar(@{$keywords}) > 0);

				if (defined $thiscomment && $thiscomment ne '') {
					if (index(lc($thiscomment), lc($keyword)) != -1) {
						return 1;
					}
					last;
				}
			}
		}
	} elsif ($filter->{'id'} eq 'tracktitlekeyword') {
		my $thistracktitle = $track->title;
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'titlekeyword') {
				my $titlekeywords = $parameter->{'value'};
				my $titlekeyword = $titlekeywords->[0] if (defined ($titlekeywords) && scalar(@{$titlekeywords}) > 0);

				if (defined $thistracktitle && $thistracktitle ne '') {
					if (index(lc($thistracktitle), lc($titlekeyword)) != -1) {
						return 1;
					}
					last;
				}
			}
		}
	} elsif ($filter->{'id'} eq 'recentlyplayedtrack' && $lookaheadonly == 1) {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $urlmd5 = $track->urlmd5;
				if (defined($urlmd5)) {
					my $lastPlayed;
					my $dbh = getCurrentDBH();
					my $sth = $dbh->prepare("select max(ifnull(tracks_persistent.lastPlayed,0)) from tracks_persistent where tracks_persistent.urlmd5 = ?");
					eval {
						$sth->bind_param(1, $urlmd5);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed)) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'recentlyplayedsimilartrackbysameartist') {
		require String::LCSS;
		use List::Util qw(max);
		my $started = time();
		my $curTitle = $track->title;
		my $curTitleNormalised = normaliseTrackTitle($curTitle);
		my $artist = $track->artist;

		if (defined($artist) && defined($curTitle)) {
			# get available track titles for current artist
			my @artistTracks = ();
			my ($trackTitle, $trackTitleSearch, $lastPlayed) = undef;
			my $dbh = getCurrentDBH();
			my $sth = $dbh->prepare("select tracks.title,tracks.titlesearch,ifnull(tracks_persistent.lastPlayed,0) from tracks, tracks_persistent, contributor_track where tracks.urlmd5 = tracks_persistent.urlmd5 and tracks.id = contributor_track.track and contributor_track.contributor = ? and tracks.id != ? group by tracks.id");
			eval {
				$sth->bind_param(1, $artist->id);
				$sth->bind_param(2, $track->id);
				$sth->execute();
				$sth->bind_columns(undef, \$trackTitle, \$trackTitleSearch, \$lastPlayed);
				while ($sth->fetch()) {
					push @artistTracks, {'lastplayed' => $lastPlayed, 'tracktitle' => $trackTitle, 'tracktitlesearch' => $trackTitleSearch}
				}
			};
			if ($@) {
				$log->error("Error executing SQL: $@\n$DBI::errstr");
			}
			$sth->finish();

			main::INFOLOG && $log->is_info && $log->info("Checking playlist track '".$track->titlesearch."' against all tracks by artist '".$track->artist->name."'");
			if (scalar @artistTracks > 0) {
				my ($recentlyPlayedPeriod, $similarityTreshold) = undef;
				# get filter param values
				for my $parameter (@{$parameters}) {
					if ($parameter->{'id'} eq 'time') {
						my $times = $parameter->{'value'};
						$recentlyPlayedPeriod = $times->[0] if (defined($times) && scalar(@{$times}) > 0);
					}
					if ($parameter->{'id'} eq 'similarityval') {
						my $similarityVals = $parameter->{'value'};
						$similarityTreshold = $similarityVals->[0] if (defined($similarityVals) && scalar(@{$similarityVals}) > 0);
					}
				}

				foreach (@artistTracks) {
					my $lastPlayed = $_->{'lastplayed'};
					my $thisTrackTitle = $_->{'tracktitle'};

					if (defined($lastPlayed) && defined($thisTrackTitle)) {
						# next if not played in specified recent period
						if (time() - $lastPlayed >= $recentlyPlayedPeriod) {
							main::DEBUGLOG && $log->is_debug && $log->debug('- Track NOT played recently: '.$_->{'tracktitlesearch'});
							next;
						}

						# calc LCSS/similarity
						require String::LCSS;
						use List::Util qw(max);

						main::INFOLOG && $log->is_info && $log->info('-- Track played recently, checking similarity: '.$_->{'tracktitlesearch'});

						my $thisTitleNormalised = normaliseTrackTitle($thisTrackTitle);
						main::DEBUGLOG && $log->is_debug && $log->debug("-- currentTrackTitle normalised = $curTitleNormalised");
						main::DEBUGLOG && $log->is_debug && $log->debug("-- thisTrackTitle normalised = $thisTitleNormalised");

						my @result = String::LCSS::lcss($curTitleNormalised, $thisTitleNormalised);
						main::DEBUGLOG && $log->is_debug && $log->debug('-- Longest common substring = '.Data::Dump::dump($result[0]));

						if ($result[0] && length($result[0]) > 3) { # returns undef if LCSS = zero or 1
							# similarity = max. length LCSS/track title
							my $similarity = max(length($result[0])/length($curTitleNormalised), length($result[0])/length($thisTitleNormalised)) * 100;
							main::DEBUGLOG && $log->is_debug && $log->debug('--- longest common substring = '.$result[0]);
							main::INFOLOG && $log->is_info && $log->info('--- Similarity = '.Data::Dump::dump($similarity)."\t-- ".$_->{'tracktitlesearch'});

							# skip if above similarity threshold
							if ($similarity > $similarityTreshold) {
								main::INFOLOG && $log->is_info && $log->info(">>> SKIPPING similar playlist track: $curTitle");
								main::DEBUGLOG && $log->is_debug && $log->debug('--- filter exec time = '.(time()-$started).' secs.');
								main::INFOLOG && $log->is_info && $log->info("\n");
								return 1;
							} else {
								main::INFOLOG && $log->is_info && $log->info("--- Similarity of tracks is below user-specified minimum value.");
							}
						} else {
							main::INFOLOG && $log->is_info && $log->info("--- Tracks don't have a common substring with the minimum length.");
							next;
						}
					}
				}
				main::DEBUGLOG && $log->is_debug && $log->debug('Filter exec time = '.(time()-$started).' secs.');
				main::INFOLOG && $log->is_info && $log->info("\n");
			} else {
				main::INFOLOG && $log->is_info && $log->info("- Found no further tracks by artist '".$track->artist->name."'.");
				main::INFOLOG && $log->is_info && $log->info("\n");
			}
		}
	} elsif ($filter->{'id'} eq 'onlinelibrarytrack') {
		if ($track->remote == 1 && $track->extid) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'localfilelibrarytrack') {
		if ($track->remote == 0) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'zapped') {
		my $zappedPlaylistName = Slim::Utils::Strings::string('ZAPPED_SONGS');
		my $url = Slim::Utils::Misc::fileURLFromPath(catfile($serverPrefs->get('playlistdir'), $zappedPlaylistName . '.m3u'));
		my $dbh = getCurrentDBH();
		my $sth = $dbh->prepare('select playlist_track.track from tracks,playlist_track where tracks.id=playlist_track.playlist and tracks.url=? and playlist_track.track=?');
		my $result = 0;
		eval {
			$sth->bind_param(1, $url);
			$sth->bind_param(2, $track->url);
			$sth->execute();
			if ($sth->fetch()) {
				$result = 1;
			}
		};
		if ($@) {
			$log->error("Error executing SQL: $@\n$DBI::errstr");
		}
		$sth->finish();
		if ($result) {
			return 1;
		}
	} elsif ($filter->{'id'} eq 'artist') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);

				my $artist = $track->artist();
				if (defined ($artist) && $artist->name eq $name) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notartist') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);
				my $artist = $track->artist();
				if (!defined ($artist) || $artist->name ne $name) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'recentlyplayedartist' && $lookaheadonly == 1) {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $artist = $track->artist;
				if (defined($artist)) {
					my $lastPlayed;
					my $dbh = getCurrentDBH();
					my $sth = $dbh->prepare("select max(ifnull(tracks_persistent.lastPlayed,0)) from tracks, tracks_persistent, contributor_track where tracks.urlmd5 = tracks_persistent.urlmd5 and tracks.id = contributor_track.track and contributor_track.contributor = ?");
					eval {
						$sth->bind_param(1, $artist->id);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed)) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'album') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'title') {
				my $titles = $parameter->{'value'};
				my $title = $titles->[0] if (defined ($titles) && scalar(@{$titles}) > 0);
				my $album = $track->album();
				if (defined ($album) && $album->title eq $title) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notalbum') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'title') {
				my $titles = $parameter->{'value'};
				my $title = $titles->[0] if (defined ($titles) && scalar(@{$titles}) > 0);
				my $album = $track->album();
				if (!defined ($album) || $album->title ne $title) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'recentlyplayedalbum' && $lookaheadonly == 1) {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $album = $track->album;
				if (defined($album)) {
					my $lastPlayed;
					my $dbh = getCurrentDBH();
					my $sth = $dbh->prepare("select max(ifnull(tracks_persistent.lastPlayed,0)) from tracks, tracks_persistent where tracks.urlmd5 = tracks_persistent.urlmd5 and tracks.album = ?");
					eval {
						$sth->bind_param(1, $album->id);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed)) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'genre') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);
				my @genres = $track->genres();
				if (@genres) {
					for my $genre (@genres) {
						if ($genre->name eq $name) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notgenre') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);
				my @genres = $track->genres();
				if (@genres) {
					my $found = 0;
					for my $genre (@genres) {
						if ($genre->name eq $name) {
							$found = 1;
						}
					}
					if (!$found) {
						return 1;
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'year') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'year') {
				my $years = $parameter->{'value'};
				my $year = $years->[0] if (defined ($years) && scalar(@{$years}) > 0);

				if (defined ($track->year) && $track->year != 0 && $track->year == $year) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'maxyear') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'year') {
				my $years = $parameter->{'value'};
				my $year = $years->[0] if (defined ($years) && scalar(@{$years}) > 0);

				if (defined ($track->year) && $track->year != 0 && $track->year <= $year) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'minyear') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'year') {
				my $years = $parameter->{'value'};
				my $year = $years->[0] if (defined ($years) && scalar(@{$years}) > 0);

				if (defined ($track->year) && $track->year != 0 && $track->year >= $year) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'playlist') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);
				my $dbh = getCurrentDBH();
				my $sth = $dbh->prepare('select playlist_track.track from tracks,playlist_track where playlist_track.playlist=tracks.id and playlist_track.track=? and tracks.title=?');
				my $result = 0;
				eval {
					$sth->bind_param(1, $track->url);
					$sth->bind_param(2, $name);
					$sth->execute();
					if ($sth->fetch()) {
						$result = 1;
					}
				};
				if ($@) {
					$log->error("Error executing SQL: $@\n$DBI::errstr");
				}
				$sth->finish();
				if ($result) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notplaylist') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'name') {
				my $names = $parameter->{'value'};
				my $name = $names->[0] if (defined ($names) && scalar(@{$names}) > 0);
				my $dbh = getCurrentDBH();
				my $sth = $dbh->prepare('select playlist_track.track from tracks,playlist_track where playlist_track.playlist=tracks.id and playlist_track.track=? and tracks.title=?');
				my $result = 0;
				eval {
					$sth->bind_param(1, $track->url);
					$sth->bind_param(2, $name);
					$sth->execute();
					if ($sth->fetch()) {
						$result = 1;
					}
				};
				if ($@) {
					$log->error("Error executing SQL: $@\n$DBI::errstr");
				}
				$sth->finish();
				if (!$result) {
					return 1;
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'virtuallibrary') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'virtuallibraryid') {
				my $VLIDs = $parameter->{'value'};
				my $VLID = $VLIDs->[0] if (defined($VLIDs) && scalar(@{$VLIDs}) > 0);
				my $VLrealID = Slim::Music::VirtualLibraries->getRealId($VLID);
				if ($VLrealID && $VLrealID ne '') {
					my $trackID = $track->id;
					my $dbh = getCurrentDBH();
					my $sth = $dbh->prepare("select library_track.track from library_track where library_track.library='$VLrealID' and library_track.track='$trackID';");
					my $result = 0;
					eval {
						$sth->execute();
						if ($sth->fetch()) {
							$result = 1;
						}
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if ($result) {
						return 1;
					}
				} else {
					main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't find virtual library with ID '$VLID'. Disabled or deleted?");
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notvirtuallibrary') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'virtuallibraryid') {
				my $VLIDs = $parameter->{'value'};
				my $VLID = $VLIDs->[0] if (defined($VLIDs) && scalar(@{$VLIDs}) > 0);
				my $VLrealID = Slim::Music::VirtualLibraries->getRealId($VLID);
				if ($VLrealID && $VLrealID ne '') {
					my $trackID = $track->id;
					my $dbh = getCurrentDBH();
					my $sth = $dbh->prepare("select library_track.track from library_track where library_track.library='$VLrealID' and library_track.track='$trackID';");
					my $result = 1;
					eval {
						$sth->execute();
						if ($sth->fetch()) {
							$result = 0;
						}
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if ($result) {
						return 1;
					}
				} else {
					main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't find virtual library with ID '$VLID'. Disabled or deleted?");
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'notactivevirtuallibrary') {
		my $enabledClientVLID = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
		main::DEBUGLOG && $log->is_debug && $log->debug('$enabledClientVLrealID = '.Data::Dump::dump($enabledClientVLID));
		my $clientID = $client->id;

		if ($enabledClientVLID && $enabledClientVLID ne '') {
			my $trackID = $track->id;
			my $dbh = getCurrentDBH();
			my $sth = $dbh->prepare("select library_track.track from library_track where library_track.library='$enabledClientVLID' and library_track.track='$trackID';");
			my $result = 1;
			eval {
				$sth->execute();
				if ($sth->fetch()) {
					$result = 0;
				}
			};
			if ($@) {
				$log->error("Error executing SQL: $@\n$DBI::errstr");
			}
			$sth->finish();
			if ($result) {
				return 1;
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("Client '$clientID' has no active virtual library");
		}
		last;
	}

	return 0;
}


## for VFD devices ##

sub setMode {
	my $class = shift;
	my $client = shift;
	my $method = shift;
	my $model = Slim::Player::Client::getClient($client->id)->model if $client;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	my @listRef = ();
	initFilters();
	my $localfilters = getFilters($client);
	for my $filter (@{$localfilters}) {
		my %item = (
			'id' => $filter->{'id'},
			'value' => $filter->{'id'},
			'filter' => $filter
		);
		push @listRef, \%item;
	}
	my %item = (
		'id' => 'disable',
		'value' => 'disable'
	);
	push @listRef, \%item;

	# use INPUT.Choice to display the list of feeds
	my %params = (
		header => ($model eq 'boom' ? '{PLUGIN_CUSTOMSKIP3_CHANGEPRIMARYFILTERSET_BOOMSHORT}' : '{PLUGIN_CUSTOMSKIP3_CHANGEPRIMARYFILTERSET}').' {count}',
		listRef => \@listRef,
		name => \&getDisplayText,
		overlayRef => \&getOverlay,
		modeName => 'PLUGIN.CustomSkip3',
		parentMode => 'PLUGIN.CustomSkip3',
		onPlay => sub { modeAction(@_); },
		onAdd => sub {
			my ($client, $item) = @_;
			main::DEBUGLOG && $log->is_debug && $log->debug('Do nothing on add');
		},
		onRight => sub { modeAction(@_); },
	);
	Slim::Buttons::Common::pushMode($client, 'INPUT.Choice', \%params);
}

sub modeAction {
	my ($client, $item) = @_;
	$client = UNIVERSAL::can(ref($client), 'masterOrSelf')?$client->masterOrSelf():$client->master();
	my $key = undef;
	if (defined ($client)) {
		$key = $client;
	}
	if (defined ($item->{'filter'}) && defined ($key)) {
		$currentFilter{$key} = $item->{'id'};
		$prefs->client($client)->set('filter', $item->{'id'});
		$currentSecondaryFilter{$key} = undef;
		$client->showBriefly({ 'line' =>
			[$client->string('PLUGIN_CUSTOMSKIP3'),
			$client->string('PLUGIN_CUSTOMSKIP3_ACTIVATING_FILTER').': '.$item->{'filter'}->{'name'}]},
			1);

	} elsif ($item->{'id'} eq 'disable' && defined ($key)) {
		$currentFilter{$key} = undef;
		$prefs->client($client)->set('filter', 0);
		$currentSecondaryFilter{$key} = undef;
		$client->showBriefly({ 'line' =>
			[$client->string('PLUGIN_CUSTOMSKIP3'),
			$client->string('PLUGIN_CUSTOMSKIP3_DISABLING_FILTER')]},
			1);
	}
}

sub getFunctions {
	return {
		'up' => sub {
			my $client = shift;
			$client->bumpUp();
		},
		'down' => sub {
			my $client = shift;
			$client->bumpDown();
		},
		'left' => sub {
			my $client = shift;
			Slim::Buttons::Common::popModeRight($client);
		},
		'right' => sub {
			my $client = shift;
			$client->bumpRight();
		}
	}
}

sub getDisplayText {
	# Returns the display text for the currently selected item in the menu
	my ($client, $item) = @_;
	my $id = undef;
	my $name = '';
	if ($item) {
		my $filter = $item->{'filter'};
		my $filteritem = $item->{'filteritem'};
		if (defined ($filteritem)) {
			$name = $filteritem->{'displayname'};
		} elsif (defined ($filter) && !defined ($item->{'name'})) {
			$name = $item->{'filter'}->{'name'};
			my $primaryFilter = getCurrentFilter($client);
			if (defined ($primaryFilter) && $item->{'id'} && $item->{'id'} eq $primaryFilter->{'id'}) {
				$name .= ' ('.string("PLUGIN_CUSTOMSKIP3_PRIMARY_ACTIVE_SHORT").')';
			} else {
				my $secondaryfilter = getCurrentSecondaryFilter($client);
				if (defined ($secondaryfilter) && $item->{'id'} && $item->{'id'} eq $secondaryfilter->{'id'}) {
					$name .= ' ('.string("PLUGIN_CUSTOMSKIP3_SECONDARY_ACTIVE").')';
				}
			}
		} elsif (defined ($item->{'id'}) && $item->{'id'} eq 'disable') {
			$name = $client->string('PLUGIN_CUSTOMSKIP3_DISABLE_FILTER');
		} else {
			$name = $item->{'name'};
		}
	}
	return $name;
}

sub getOverlay {
	# Returns the overlay/symbols displayed next to items in the menu
	my ($client, $item) = @_;
	my $filter = getCurrentFilter($client);
	my $itemFilter = $item->{'filter'};

	if ((!defined ($itemFilter) && !defined($filter)) || (defined($itemFilter) && defined($filter) && $itemFilter->{'id'} eq $filter->{'id'})) {
		return [undef, undef];
	} else {
		return [undef, $client->symbols('rightarrow')];
	}
}



### helpers ###

sub getVirtualLibraries {
	my (@items, @hiddenVLs);
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	main::DEBUGLOG && $log->is_debug && $log->debug('ALL virtual libraries: '.Data::Dump::dump($libraries));

	foreach my $realVLID (sort {lc($libraries->{$a}->{'name'}) cmp lc($libraries->{$b}->{'name'})} keys %{$libraries}) {
		my $count = Slim::Music::VirtualLibraries->getTrackCount($realVLID);
		my $name = $libraries->{$realVLID}->{'name'};
		my $displayName = Slim::Utils::Unicode::utf8decode($name, 'utf8');
		$displayName =~ s/[\$#@~!&*()\[\];.,:?^`\\\/]+//g;
		$displayName = $displayName.' ('.Slim::Utils::Misc::delimitThousands($count).($count == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TRACK") : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TRACKS")).')';
		my $VLID = $libraries->{$realVLID}->{'id'};
		main::DEBUGLOG && $log->is_debug && $log->debug('displayName = '.$displayName.' -- VLID = '.$VLID);
		push @items, qq($VLID).'='.$displayName;
	}
	my $dataString = join (',', @items);

	if (scalar @items == 0) {
		$dataString = 'undef='.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_NOVLIBS");
	}

	return $dataString;
}

sub createCustomSkipFolder {
	my $customskipParentFolderPath = $prefs->get('customskipparentfolderpath') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $customskipFolderPath = catdir($customskipParentFolderPath, 'CustomSkip3');
	eval {
		mkdir($customskipFolderPath, 0755) unless (-d $customskipFolderPath);
	} or do {
		$log->error("Could not create CustomSkip3 folder in parent folder '$customskipParentFolderPath'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
		return;
	};
	$prefs->set('customskipfolderpath', $customskipFolderPath);
}

sub displayErrorMessage {
	my $client = shift;
	my $errorMessage = shift;
	if (Slim::Buttons::Common::mode($client) !~ /^SCREENSAVER./) {
		$client->showBriefly({'line' => [string('PLUGIN_CUSTOMSKIP3'), $errorMessage]}, 4);
	}
	if (Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')) {
		Slim::Control::Request::executeRequest(undef, ['material-skin', 'send-notif', 'type:info', 'msg:'.$errorMessage, 'client:'.$client->id, 'timeout:4']);
	}
}

sub prettifyTime {
	my $timeinseconds = shift;
	my $seconds = (int($timeinseconds)) % 60;
	my $minutes = (int($timeinseconds / (60))) % 60;
	my $hours = (int($timeinseconds / (60*60))) % 24;
	my $days = (int($timeinseconds / (60*60*24))) % 7;
	my $weeks = (int($timeinseconds / (60*60*24*7))) % 52;
	my $years = (int($timeinseconds / (60*60*24*365))) % 10;
	my $prettyTime = (($years > 0 ? $years.($years == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_YEAR").'  ' : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_YEARS").'  ') : '').($weeks > 0 ? $weeks.($weeks == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK").'  ' : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEKS").'  ') : '').($days > 0 ? $days.($days == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAY").'  ' : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").'  ') : '').($hours > 0 ? $hours.($hours == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").'  ' : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").'  ') : '').($minutes > 0 ? $minutes.($minutes == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MIN").'  ' : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").'  ') : '').($seconds > 0 ? $seconds.($seconds == 1 ? ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SEC") : ' '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_SECS")) : ''));
	return $prettyTime;
}

sub getMusicInfoSCRCustomItems {
	my $customFormats = {
		'CUSTOMSKIPFILTERS' => {
			'cb' => \&getTitleFormatActive,
			'cache' => 5,
		},
		'CUSTOMSKIPFILTER' => {
			'cb' => \&getTitleFormatActive,
			'cache' => 5,
		},
		'CUSTOMSKIPSECONDARYFILTER' => {
			'cb' => \&getTitleFormatActive,
			'cache' => 5,
		},
	};
	return $customFormats;
}

sub getTitleFormatActive { # called from getMusicInfoSCRCustomItems
	my $client = shift;
	my $song = shift;
	my $tag = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Entering getTitleFormatActive');
	my @activeFilters = ();
	if ($tag =~ /^CUSTOMSKIPFILTER/) {
		my $filter = getCurrentFilter($client);
		if (defined ($filter)) {
			push @activeFilters, $filter;
		}
	}
	if ($tag =~ /^CUSTOMSKIPSECONDARYFILTER/ || $tag =~ /^CUSTOMSKIPFILTERS/) {
		my $filter = getCurrentSecondaryFilter($client);
		if (defined ($filter)) {
			push @activeFilters, $filter;
		}
	}

	my $filterString = undef;
	foreach my $filter (@activeFilters) {
		if (defined $filterString) {
			$filterString .= ',';
		} else {
			$filterString = '';
		}
		$filterString .= $filter->{'name'};
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Exiting getTitleFormatActive with $filterString");
	return $filterString;
}

sub getCurrentDBH {
	return Slim::Schema->storage->dbh();
}

sub objectForId {
	my $type = shift;
	my $id = shift;
	if ($type eq 'artist') {
		$type = 'Contributor';
	} elsif ($type eq 'album') {
		$type = 'Album';
	} elsif ($type eq 'genre') {
		$type = 'Genre';
	} elsif ($type eq 'track') {
		$type = 'Track';
	} elsif ($type eq 'playlist') {
		$type = 'Playlist';
	} elsif ($type eq 'year') {
		$type = 'Year';
	}
	return Slim::Schema->resultset($type)->find($id);
}

sub objectForUrl {
	my $url = shift;
	return Slim::Schema->objectForUrl({
		'url' => $url
	});
}

sub getLinkAttribute {
	my $attr = shift;
	if ($attr eq 'artist') {
		$attr = 'contributor';
	}
	return $attr.'.id';
}

sub roundFloat {
	my $float = shift;
	return int($float + $float/abs($float*2 || 1));
}

sub normaliseTrackTitle {
	my $title = shift;
	return if !$title;
	$title =~ s/[\[\(].*[\)\]]*//g; # delete everything between brackets + parentheses
	$title =~ s/((bonus|deluxe|12“|live|extended|instrumental|edit|interlude|alt\.|alternate|alternative|album|single|ep|maxi)+[ -]*(version|remix|mix|take|track))//ig; # delete some common words
	$title = uc(Slim::Utils::Text::ignoreCase($title, 1));
	return $title;
}

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
