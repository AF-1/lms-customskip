Custom Skip
====

Custom Skip lets you define client-specific filter sets with rules for when tracks should be skipped.<br>
Over the years I've adapted *Custom Skip* to my needs and taste: adding *look-ahead filtering* or *virtual library filter rules*, changing the UI etc. The result is this version. Feel free to use it.<br>It's not an 'official' version. So although I'm interested in keeping it running<br><br>
**I'm not maintaining CustomSkip nor am I providing any support for it.**<br><br>
Some preferences are not enabled by default.

<br><br>

## Installation

### Using the repository URL

- If necessary (previous manual install), uninstall your previous CustomSkip version
- Add the repository URL below at the bottom of *LMS* > *Settings* > *Plugins*:<br>
[https://raw.githubusercontent.com/AF-1/lms-customskip/main/public.xml](https://raw.githubusercontent.com/AF-1/lms-customskip/main/public.xml)
- Reload the *LMS* > *Settings* > *Plugins* page. The CustomSkip repository should now be displayed somewhere at the bottom of the page.
- Install the new version
<br><br>

### Manual Install

* go to *LMS* > *Settings* > *Plugins* and uninstall the currently installed version of *Custom Skip*.

* then go to *LMS* > *Settings* > *Information*. Near the bottom of the page you'll find several plugin folder paths. The *path* you're looking for does **not** include the word *Cache* and it's not the server plugin folder that contains built-in LMS plugins. Examples of correct paths:
    * *piCorePlayer*: /usr/local/slimserver/Plugins
    * *Mac*: /Users/yourusername/Library/Application Support/Squeezebox/Plugins

* now click the green *Code* button and download the zip archive. Move the folder called *CustomSkip* from that archive into the plugin folder mentioned above.

* restart LMS
<br><br><br>


## Uninstall

### Using the repository URL

- Uninstall CustomSkip
- Delete the repository URL you added at the bottom of *LMS* > *Settings* > *Plugins*
- restart LMS
- Reinstall the old version
<br><br>

### Manual Uninstall

- delete the folder *CustomSkip* from your local plugin folder
- restart LMS
- reinstall the old version
<br><br>

## FAQ

- »**I can't find my filter *sets*.**«<br>
CustomSkip v3+ automatically creates a CustomSkip folder at a location that you can set in the CustomSkip settings. The default location was (in v2) and still is the **LMS playlist folder**. Grouping CustomSkip filter set files in a dedicated subfolder helps reduce clutter. Just move your old filter set files (file extension **.cs.xml**) into the new subfolder. You can also move the CustomSkip folder out of the LMS playlist folder to any other location (with the necessary file permissions for LMS).<br><br>

- »**How can I make CustomSkip filter only dynamic playlist tracks?**«<br>
Explained in the [wiki](https://github.com/AF-1/lms-customskip/wiki#i-want-customskip-to-filter-only-dynamic-playlist-tracks).<br><br>

- »**What's the difference between a *primary* and a *secondary* filter set?**«<br>
Explained in the [wiki](https://github.com/AF-1/lms-customskip/wiki#primary-and-secondary-filter-sets).<br><br>

- »**Can I call CustomSkip from the context menu?**«<br>
*Artists*, *albums*, *genres*, *years*, *tracks* and *playlists* have a CustomSkip content menu that lets you add a filter/skip rule to the **active primary** filter set. Example: you want to skip all tracks of the selected artist for the next 15 minutes.<br><br>

- »**Does CustomSkip handle online tracks?**«<br>
CustomSkip will process **online tracks** that have been **added to your LMS library as part of an album**. LMS does not import **single** online tracks or tracks of *online* **playlists** as **library** tracks and therefore they won't be processed by CustomSkip.<br><br>

- »**The web menu doesn't have a filter item/rule for skipping single tracks. How can I skip single tracks?**«<br>
You can create a skip rule for single tracks from a track's context menu.<br><br>

- »**Look-ahead filtering doesn't delete all tracks that should be filtered but always leaves one in the playlist.**«<br>
Custom Skip's look-ahead filtering will leave at least one last track in the playlist after the currently playing track to avoid problems with plugins that use song change events to trigger actions.<br><br>