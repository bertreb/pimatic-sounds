# pimatic-sounds
Pimatic plugin for playing mp3 files and tts sentences on Chromecast and Sonos devices. A typical chromecast device devices is Google Home or a Google chromecast dongle. The Ikea SYMFONISK is a Sonos device.

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

### Chromecast Device
Create a Chromecast device with the following config.

```
{
  "id": "testcast",         // id for usage within Pimatic
  "name": "testcast",       // name for usage within Pimatic
  "class": "ChromecastDevice"
  "ip": "192.168.xxx.xxx",  // IP of your Chromecast device
  "playInit": true          // plays initSound.mp3 after (re)start of device
  "xAttributeOptions": [],
}
```
### Sonos Device
Create a Sonos device with the following config.

```
{
  "id": "testcast",         // id for usage within Pimatic
  "name": "testcast",       // name for usage within Pimatic
  "class": "SonosDevice"
  "ip": "192.168.xxx.xxx",  // IP of your Chromecast device
  "playInit": true          // plays initSound.mp3 after (re)start of device
  "xAttributeOptions": [],
}
```
## Controlling the devices

The function of a device is controlled via rules
The ACTION rule syntax is:

**play** [text|file|vol] ["test text for tts"|"filename"] [**vol** [0-100]] **on** [ChromecastDevice]

The 3 type of command lines are:
1. **play text** "this is a nice text" **vol** 50 **on** mysoundsdevice
2. **play file** "nice-music.mp3" **vol** 25 **on** mysoundsdevice
4. **play vol** [0-100] **on** mysoundsdevice

In the main directory of Pimatic (mostly /home/pi/pimatic-app) a directory sounds is created. You can put mp3 files in that directory. You can create subdirectories in sounds and can use them in the rule.

In the text string you can use variables to create dynamic voice text.

You can set the mainvolume with the command 'play vol [0-100] on mysoundsdevice'.
The 'vol [0-100]' after text or file is optional and will override the mainvolume. If not set, the value of the mainvolume is 20.

When a TuneIn stream is playing and Sounds plays a text or file, the TuneIn stream stops and is resumed after the Sounds play is finished.

The mp3 filenames ***must be without spaces!***

## Discovery
In the devices section of the Gui you can use the device discovery to discover and add Chromecast or Sonos devices.
Devices that are already in the config are not shown.

----
The plugin is **only Node v8 or v10** compatible and in development.

You could backup Pimatic before you are using this plugin!
