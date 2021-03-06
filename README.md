Custom Skip 3
====

*Custom Skip 3* lets you define client-specific filter sets with *rules* for when tracks should be skipped **automatically**.<br>
Some preferences are not enabled by default.
<br><br>

## Requirements

- LMS version >= 7.**9**
- LMS database = **SQLite**
<br><br><br>


## Features:
* Comes with 30 ready-to-use skip/filter rules.
* **Look-ahead filtering**: Have <i>Custom Skip v3</i> check not only the current song, but also the following songs to see if they have to be skipped/removed from the playlist. Helps avoiding short but unpleasant playback interruptions when a current song is skipped.
* Use the context menu to (temporarily) filter </i>artists</i>, <i>albums</i>, <i>genres</i>, <i>years</i>, <i>tracks</i> or <i>playlists</i>.
* Should work with **online library tracks** (see [**FAQ**](https://github.com/AF-1/lms-customskip#faq)).
* Clear and informative user interface.
* …
<br><br><br><br>


## Installation

⚠️ **Please read the [FAQ](https://github.com/AF-1/lms-customskip#faq) *before* installing this plugin.**<br>

You should be able to install **Custom Skip 3** from the LMS main repository (LMS plugin library): **LMS > Settings > Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.
<br><br><br><br>


## Translation
The [**strings.txt**](https://github.com/AF-1/lms-customskip/blob/main/CustomSkip3/strings.txt) file contains all localizable strings. Once you're done **testing** the plugin with your translated strings just create a pull request on GitHub.<br>
* Please try not to use the [**single**](https://www.fileformat.info/info/unicode/char/27/index.htm) quote character (apostrophe) or the [**double**](https://www.fileformat.info/info/unicode/char/0022/index.htm) quote character (quotation mark) in your translated strings. They could cause problems. You can use the [*right single quotation mark*](https://www.fileformat.info/info/unicode/char/2019/index.htm) or the [*double quotation mark*](https://www.fileformat.info/info/unicode/char/201d/index.htm) instead. And if possible, avoid (special) characters that are used as [**metacharacters**](https://en.wikipedia.org/wiki/Metacharacter) in programming languages (Perl), regex or SQLite.
* It's probably not a bad idea to keep the translated strings roughly as long as the original ones.<br>
* Some of these strings are supposed to be used with different UIs: my tests usually cover the LMS *default* skin, *Material* skin, *piCorePlayer* (or any other jivelite player like *SqueezePlay*) and maybe some ip3k player like *Boom* if applicable.
* Please leave *(multiple) blank lines* (used to visually delineate different parts) as they are.
<br><br><br><br>


## FAQ

<details><summary>»<b>I can't find my filter <i>sets</i>.</b>«</summary><br><p>
</i>Custom Skip <b>3</b></i> automatically creates a folder called <b>CustomSkip3</b> at a location that you can set in the CustomSkip settings. The default location is the <b>LMS playlist folder</b>. Grouping CustomSkip filter set files in a dedicated subfolder helps reduce clutter. Just move your old filter set files (file extension <b>.cs.xml</b>) into the new subfolder. You can also move the CustomSkip3 folder out of the LMS playlist folder to any other location (with the necessary file permissions for LMS).</p></details><br>

<details><summary>»<b>How can I make CustomSkip filter only dynamic playlist tracks?</b>«</summary><br><p>
Explained in the <a href="https://github.com/AF-1/lms-customskip/wiki#i-want-customskip-to-filter-only-dynamic-playlist-tracks">wiki</a>.</p></details><br>

<details><summary>»<b>What's the difference between a <i>primary</i> and a <i>secondary</i> filter set?</b>«</summary><br><p>
Explained in the <a href="https://github.com/AF-1/lms-customskip/wiki#primary-and-secondary-filter-sets">wiki</a>.</p></details><br>

<details><summary>»<b>Can I call CustomSkip3 from the context menu?</b>«</summary><br><p>
</i>Artists</i>, <i>albums</i>, <i>genres</i>, <i>years</i>, <i>tracks</i> and <i>playlists</i> have a CustomSkip content menu that lets you add a filter/skip rule to the <b>active primary</b> filter set. Example: you want to skip all tracks of the selected artist for the next 15 minutes.</p></details><br>

<details><summary>»<b>Does CustomSkip3 handle online tracks?</b>«</summary><br><p>
CustomSkip3 will process <b>online tracks</b> that have been <b>added to your LMS library as part of an album</b>. LMS does not import <b>single</b> online tracks or tracks of <i>online</i> <b>playlists</b> as <b>library</b> tracks and therefore they won't be processed by CustomSkip3.</p></details><br>

<details><summary>»<b>The web menu doesn't have a filter rule for skipping single tracks. How can I skip single tracks?</b>«</summary><br><p>
You can create a skip rule for single tracks from a track's context menu.</p></details><br>

<details><summary>»<b>Look-ahead filtering doesn't delete all tracks that should be filtered but always leaves one in the playlist.</b>«</summary><br><p>
Custom Skip's look-ahead filtering will leave at least one last track in the playlist after the currently playing track to avoid problems with plugins that use song change events to trigger actions.</p></details><br>

<details><summary>»<b>Is Custom Skip v3 compatible with Dynamic Playlists v2?</b>«</summary><br><p>
</i>Custom Skip v</b>3</b></i> works with <i>Dynamic Playlists</i> version <b>3</b>. Anything else is untested and unsupported.</p></details><br>

<details><summary>»<b>I still use SQLPlayList. After updating to Custom Skip 3 the SQLPlayList plugin does no longer display the dropdown menu for selecting a Custom Skip filter set.</b>«</summary><br><p>
The plugin code of SQLPlayList 2.6.272 still contains references to the old plugin names. If you absolutely have to use Custom Skip 3 with SQLPlayList there's an equally <a href="https://github.com/AF-1/lms-sqlplaylist">unsupported and unmaintained version of <b>SQLPlayList</b></a> with updated plugin name references. No guarantees and no support though. Please remember that.</p></details><br>

<details><summary>»<b>Why are the filter rules '<i>recently played track/artist/album</i>' only available for look-ahead filtering?</b>«</summary><br><p>
As soon as a new song starts playing LMS will set its <i>last time played</i> to the <i>current</i> time and <b>then</b> notify other plugins like Custom Skip 3 of the song change event. So Custom Skip's filtering doesn't kick in until <b>after</b> the <i>last time played</i> has been set to the <i>current</i> time. Therefore if Custom Skip 3 checked currently playing tracks against a <i>recently played</i> filter rule it would find that <i>all</i> currently playing tracks have been recently played and skip them resulting in endless skipping. That's why these rules are only available for look-ahead filtering.</p></details><br>

<br><br><br><br>

## Bug reports

If you're **reporting a bug** please **include relevant server log entries and the version number of LMS, Perl and your OS**. You'll find all of that on the  *LMS* > *Settings* > *Information* page.

Please post bug reports *only* [**here**](https://forums.slimdevices.com/showthread.php?115874-Announce-Custom-Skip-3).
