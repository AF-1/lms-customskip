Custom Skip
====

This version of CustomSkip should restore skipping on dynamic playlists with the Dynamic Playlists plugin version 3+.<br><br>
**I'm not maintaining CustomSkip nor am I providing any support for it.**


<br><br>

## Installation

### Using repo URL

- Uninstall your previous CustomSkip version
- Add the repo URL below at the bottom of *LMS* > *Settings* > *Plugins*:<br>
[https://raw.githubusercontent.com/AF-1/lms-customskip/main/public.xml](https://raw.githubusercontent.com/AF-1/lms-customskip/main/public.xml)
- Install the new version
<br><br>

### Manual Install

* go to  *LMS* > *settings > plugins* and uninstall the currently installed version of *Custom Skip*.

* then go to *LMS* > *settings > information*. Near the bottom of the page you'll find several plugin folder paths. The *path* you're looking for does **not** include the word *Cache* and it's not the server plugin folder that contains built-in LMS plugins. Examples of correct paths:
    * *piCorePlayer*: /usr/local/slimserver/Plugins
    * *Mac*: /Users/yourusername/Library/Application Support/Squeezebox/Plugins

* now click the green *Code* button and download the zip archive. Move the folder called *CustomSkip* from that archive into the plugin folder mentioned above.

* restart LMS
<br><br><br>


## Uninstall

### Using repo URL

- Uninstall CustomSkip
- Delete the repo URL you added at the bottom of *LMS* > *Settings* > *Plugins*
- restart LMS
- Reinstall the old version
<br><br>

### Manual Uninstall

- delete the folder *CustomSkip* from your local plugin folder
- restart LMS
- reinstall the old version