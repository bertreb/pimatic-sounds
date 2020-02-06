# pimatic-sounds
Pimatic plugin for playing sounds and tts sentences on Chromecast devices

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

create a SoundsDevice with the following config

```
{
  "id": "testkast",         // id for usage within Pimatic
  "name": "testkast",       // name for usage within Pimatic
  "class": "SoundsDevice"
  "ip": "192.168.xxx.xxx",  // IP of the  Chromecast device
  "xAttributeOptions": [],
}
```

The function is controlled via rules
The ACTION rule syntax is

**play** [text|file] ["test for tts"|"filename"] **vol** [0-100] **on** [SoundsDevice]

In the min directory of Pimatic (/home/pi/pimatic-app) a directory sounds is created. You can put mp3 files in that directory. You can create subdirectories and can use them in the rule.

----
The plugin is Node v10 compatible and in development. You could backup Pimatic before you are using this plugin!
