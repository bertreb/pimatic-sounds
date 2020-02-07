# pimatic-sounds
Pimatic plugin for playing mp3 files and tts sentences on Chromecast devices

Install the plugin via the plugin page of Pimatic or add the following in config.json
```
 {
   "plugin": "sounds"
 }
```
After installation and restart activate the plugin and add the following to the plugin config
```
{
  "port": 8088,     // or the port you like and is free
  "language": "en", // or your own language
  "debug": true     // if you want
}

```
The IP address of the computer the plugin is running on, is automatically detected and used for the media server. It must be in the range 192.168.xxx.xxx.
The supported (but not tested) languages can be found in  [languages](https://github.com/bertreb/pimatic-sounds/blob/master/languages).

Create a SoundsDevice with the following config

```
{
  "id": "testcast",         // id for usage within Pimatic
  "name": "testcast",       // name for usage within Pimatic
  "class": "SoundsDevice"
  "ip": "192.168.xxx.xxx",  // IP of your Chromecast device
  "playInit": true          // plays initSound.mp3 after (re)start of device
  "xAttributeOptions": [],
}
```

The function is controlled via rules
The ACTION rule syntax is:

**play** [text|file|stop|vol] ["test text for tts"|"filename"] [**vol** [0-100]] **on** [SoundsDevice]

The 4 type of command lines are:
1. **play text** "this is a nice text" **vol** 50 **on** mychromecast
2. **play file** "nice-music.mp3" **vol** 25 **on** mychromecast
3. **play stop** mychromecast  // stops current playing sound
4. **play vol** [0-100] **on** mychromecast

In the main directory of Pimatic (mostly /home/pi/pimatic-app) a directory sounds is created. You can put mp3 files in that directory. You can create subdirectories in sounds and can use them in the rule.

You can set the mainvolume with the command 'play vol [0-100] on mychromecast'.
The 'vol [0-100]' after text or file is optional and will override the mainvolume. If not set, the value of the mainvolume is 20.

The mp3 filenames ***must be without spaces!***

----
The plugin is **only Node v8 or v10** compatible and in development.

You could backup Pimatic before you are using this plugin!
