Custom Skip 3
====

*Custom Skip 3* lets you define client-specific filter sets with rules for when tracks should be skipped.<br>
Changes include look-ahead filtering, new filter rules, some context menus and UI changes.<br><br>
Some preferences are not enabled by default.
<br><br>

## Installation

⚠️ **Please read the [FAQ](https://github.com/AF-1/lms-customskip#faq) *before* installing this plugin.**<br>

You should be able to install **Custom Skip 3** from the LMS main repository (LMS plugin library): **LMS > Settings > Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.
<br><br><br>


## FAQ

<details><summary>»**I can't find my filter *sets*.**«</summary><br><p>
*Custom Skip **3*** automatically creates a folder called **CustomSkip3** at a location that you can set in the CustomSkip settings. The default location is the **LMS playlist folder**. Grouping CustomSkip filter set files in a dedicated subfolder helps reduce clutter. Just move your old filter set files (file extension **.cs.xml**) into the new subfolder. You can also move the CustomSkip3 folder out of the LMS playlist folder to any other location (with the necessary file permissions for LMS).</p></details><br>

<details><summary>»**How can I make CustomSkip filter only dynamic playlist tracks?**«</summary><br><p>
Explained in the <a href="https://github.com/AF-1/lms-customskip/wiki#i-want-customskip-to-filter-only-dynamic-playlist-tracks">wiki</a>.</p></details><br>

<details><summary>»**What's the difference between a *primary* and a *secondary* filter set?**«</summary><br><p>
Explained in the <a href="https://github.com/AF-1/lms-customskip/wiki#primary-and-secondary-filter-sets">wiki</a>.</p></details><br>

<details><summary>»**Can I call CustomSkip3 from the context menu?**«</summary><br><p>
*Artists*, *albums*, *genres*, *years*, *tracks* and *playlists* have a CustomSkip content menu that lets you add a filter/skip rule to the **active primary** filter set. Example: you want to skip all tracks of the selected artist for the next 15 minutes.</p></details><br>

<details><summary>»**Does CustomSkip3 handle online tracks?**«</summary><br><p>
CustomSkip3 will process **online tracks** that have been **added to your LMS library as part of an album**. LMS does not import **single** online tracks or tracks of *online* **playlists** as **library** tracks and therefore they won't be processed by CustomSkip3.</p></details><br>

<details><summary>»**The web menu doesn't have a filter rule for skipping single tracks. How can I skip single tracks?**«</summary><br><p>
You can create a skip rule for single tracks from a track's context menu.</p></details><br>

<details><summary>»**Look-ahead filtering doesn't delete all tracks that should be filtered but always leaves one in the playlist.**«</summary><br><p>
Custom Skip's look-ahead filtering will leave at least one last track in the playlist after the currently playing track to avoid problems with plugins that use song change events to trigger actions.</p></details><br>

<details><summary>»**Is Custom Skip v3 compatible with Dynamic Playlists v2?**«</summary><br><p>
*Custom Skip v**3*** works with *Dynamic Playlists* version **3**. Anything else is untested and unsupported.</p></details><br>

<details><summary>»**I still use SQLPlayList. After updating to Custom Skip 3 the SQLPlayList plugin does no longer display the dropdown menu for selecting a Custom Skip filter set.**«</summary><br><p>
The plugin code of SQLPlayList 2.6.272 still contains references to the old plugin names. If you absolutely have to use Custom Skip 3 with SQLPlayList there's an equally <a href="https://github.com/AF-1/lms-sqlplaylist">unsupported and unmaintained version of **SQLPlayList**</a> with updated plugin name references. No guarantees and no support though. Please remember that.</p></details><br>

<details><summary>»**Why are the filter rules '*recently played track/artist/album*' only available for look-ahead filtering?**«</summary><br><p>
As soon as a new song starts playing LMS will set its *last time played* to the *current* time and **then** notify other plugins like Custom Skip 3 of the song change event. So Custom Skip's filtering doesn't kick in until **after** the *last time played* has been set to the *current* time. Therefore if Custom Skip 3 checked currently playing tracks against a *recently played* filter rule it would find that *all* currently playing tracks have been recently played and skip them resulting in endless skipping. That's why these rules are only available for look-ahead filtering.</p></details><br>