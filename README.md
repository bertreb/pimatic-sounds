# pimatic-sounds
Pimatic plugin for playing mp3 files and tts sentences on Chromecast and Sonos devices. A typical chromecast device devices is Google Home or a Google chromecast dongle. The Ikea SYMFONISK is a Sonos device. There are 2 options for using Google devices.
1. Use the Chromecast option (ChromecastDevice). This can be used without any action in the Google cloud. The announcement function works in limited cases (tested only with tuneIn). In some cases the currently playing stream with be stopped when an annoucement is played.
2. Use the Assistant option (GoogleDevice). In this option an announcement will just pause the currently playing stream and the stream will continue after the announcement. For this option you need to configure 'an assistant device' in Google Cloud ([instructions](https://greghesp.github.io/assistant-relay/docs/introduction)). If you installed assistant-relay on an other system then you need to install the python library catt on your pimatic system (see [install catt](https://github.com/skorokithakis/catt)). Use 'sudo pip3 install catt' to get a systemwide command.

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
  "soundsDirectory": "directory for sounds, defaults is '/sounds' in pimatic home directory"
  "tts": ["google-translate","google-cloud"] // select tts engine
  "googleCloudJson": "<if tts engine is google-cloud the filename of the credential json file>" // incl .json extension
  "voice": "The name of the voice, format is <language-code>-Standard-[A,B,C,D]"
  "pitch: "The increase or decrease in semitones of the voice pitch (-20 to +20)"
  "speakingRate: "The speed of the voice (0.25 to 4.0)"
  "assistantRelay: "Enable to use for GoogleDevice (if assistant-relay is installed)"
  "assistantRelayIp: "The IP address of the assistant-relay server"
  "assistantRelayPort: "The Port number of the assistant-relay server"
  "assistantRelayUser: "The username for assistant-relay"
  "debug": true     // if you want
}

```
The IP address of the computer the plugin is running on, is automatically detected and used for the media server. It must be in the range 192.168.xxx.xxx.


If you are using assistant-relay you need to install it before you use that in this plugin. The installation instructions are [here](https://greghesp.github.io/assistant-relay/docs/introduction). Configure and activate assistant-relay first. You can install it on any computer as long it is in the same lan network pimatic and you're google devices are running on. The ip number of the computer assistant-relay is running on and the port number (default 3000) are used in this plugin. The username you used in configuring the google credentials is used also (linked to the downloaded json file with the secret).

The tts and googleCloudJson for the GoogleDevice are not used because the text to voice conversion is handled via assistant-relay.
Via the management/config menu of assistant-relay you can set the language option, enable casting and announcement, etc.

### Google Cloud text-to-speech
Create credential.json file by following [the procedure](https://cloud.google.com/text-to-speech/docs/quickstart-client-libraries?hl=en) and follow the 'before you begin' steps until step 4f (download the json file). Put the json file in your pimatic-app directory.

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
The Cromecast device types are a single, grouped or paired devices. The discovery will find them and they can be added and used in the rules

### Google Device
Create a Google device with the following config.

```
{
  "id": "testcast",         // id for usage within Pimatic
  "name": "testcast",       // name for usage within Pimatic
  "class": "GoogleDevice"
  "ip": "192.168.xxx.xxx",  // IP of your Google device
  "playInit": true          // plays initSound.mp3 after (re)start of device
  "xAttributeOptions": [],
}
```
The GoogleDevice is found and added via the discovery.


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

### Group Device
Create a Group device with the following config.

```
{
  "id": "testgroupcast",      // id for usage within Pimatic
  "name": "testgroupcast",    // name for usage within Pimatic
  "class": "GroupDevice"
  "playInit": true            // plays initSound.mp3 after (re)start of device
  "devices": [                // list of SoundsDevices
    "name": "id of a SoundDevice"
    ]
  "xAttributeOptions": [],
}
```
The GroupDevice is combining existing SoundsDevices to be used as an extra device.
In the GroupsDevice config you can select and add existing SoundsDevices.
In the rules the groups device will be available as an extra play device option.

## Controlling the devices

The function of a device is controlled via rules
The ACTION rule syntax is:

**play**  [text|ask|file|main|stop]  ["$variable"|"text for tts"]|["audio filename"|"$variable"]  [**vol** [number|$variable]]  **on**  [ChromecastDevice | SonosDevice | GroupDevice] [**for** [xx|$variable] [seconds..years]]

Some examples of command lines are:
1. **play text** "this is a nice text" **vol** 50 **on** mysoundsdevice
2. **play ask** "what's the weather" **on** **GoogleDevice**
3. **play file** "nice-music.mp3" **vol** 25 **on** mysoundsdevice
4. **play file** "$that-funky-music" vol $loud-music **on** mysoundsdevice
5. **play file** "$that-funky-music" vol $loud-music **on** mysoundsdevice **for** 10 seconds
6. **play main** vol $loud-music **on** mysoundsdevice
7. **play stop on** mysoundsdevice

In the main directory of Pimatic (mostly /home/pi/pimatic-app) a directory sounds is created. You can put mp3 files in that directory. You can create subdirectories in sounds and can use them in the rule.

In the text string you can use variables to create dynamic voice text.

In the file string you can also use variables to create dynamic selection of audio files. A variable-only file string must still be enclosed by "". The resulting filenames ***must be without spaces!***

For the volume variable a number or a variable can be used.

The 'vol [0-100]' after text or file is optional and will override the mainvolume. If not set, the value of the mainvolume is 20.

The duration option (for ...) is used when announcing/displaying info for a certain time. The value can be a number or a variable containing a number.
When using a variable the unit (seconds..years) is fixed in the rule and the variable holds the value.

When a TuneIn stream is playing and Sounds plays a text or file, the TuneIn stream stops and is resumed after the Sounds play is finished. 

On a GoogleDevice you can ask a question ('play ask ...'). The answer is being played via the GoogleDevice.

## Attributes
The following 3 attributes are created:
- status: the device status like playing, paused, etc
- info: informatie about the currently playing/paused media
- volume: the currently active volume level (0-100)

### Credits
This plugin is build from several existing pieces of software. Sometimes the ideas and sometimes the real pieces of code. To mention are:
- castv2-client from thibauts
- node-red-contrib-castv2 from i8beef
- node-sonos from bencevans
- assistant-relay from greghesp
---
The plugin is **only Node v8 or v10** compatible and in development.

You could backup Pimatic before you are using this plugin!
