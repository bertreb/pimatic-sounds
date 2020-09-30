# Release History

* 20200206, v0.0.8
	* initial release
* 20200206, v0.0.9
	* added dependency
	* 20200206, v0.0.9
		* added dependency
* 20200207, v0.0.11
	* extra main volume command
	* added initSound on (re)start of device
* 20200208, v0.0.12
	* rename 1e device to ChromecastDevice
* 20200212, v0.0.13
	* replay of TuneIn stream after Text or File play
* 20200213, v0.0.14
	* added Sonos (+SYMFONISK) devices
	* moved webserver to plugin level
* 20200213, v0.0.15
	* added device discovery
	* volume stays on same level after Sounds playing
	* possibility to use variables in text string
* 20200213, v0.0.16
	* discovery removed due to mdns install issues
* 20200214, v0.0.17
	* improved error handling
* 20200214, v0.0.18
	* wrong status info when playing Sounds
	* bugfix filename
* 20200215, v0.0.19
	* error message on spaces in rule filename
	* fix setting port number
	* stop casting after text or file announcement
	* improved media file typing
	* adding variable in filename string
* 20200215, v0.0.20
	* fix replay live stream
* 20200216, v0.0.21
	* improved error message handling
	* changed on/offline checker to 1 minute
	* changed startup delay to 15 seconds
* 20200217, v0.0.23
	* added group device
	* added $variable or number for volume setting
* 20200218, v0.0.27
	* added device discovery for Chromecast single, groups and pairs
	* better naming in discovery
	* release for testing NOT FOR PRODUCTION
* 20200221, v0.0.28
	* set discovery to manual only via Pimatic Gui
	* after connection loss a reconnect try will be in 10 minutes
	* removed the separate volume setting option
	* several optimalizations
* 20200222, v0.0.29
	* bug fix GroupsDevice
* 20200223, v0.0.30
	* fix discovery flooding
* 20200224, v0.0.31
	* move non essential error messages to debug
* 20200306, v0.0.32
	* fix startup bug sonos
* 20200306, v0.0.34
	* added error handling
* 20200320, v0.0.35
	* added setting of mainvolume
* 20200320, v0.0.38
	* fix playing text/file
* 20200331, v0.0.39
	* fix info after announcement and pause
* 20200608, v0.0.44
	* added Google Cloud Text-to-speech
* 20200608, v0.0.45
	* edit startup check
* 20200608, v0.0.47
	* update rule engine
* 20200624, v0.0.48
	* added stop function
* 20200817, v0.1.3
	* added GoogleDevice based on assistant-relay
* 20200907, v0.1.6
	* improved error handling
* 20200926, v0.1.7
	* set duration picture announcement
* 20200926, v0.1.8
	* pictures must be swipped off
* 20200928, v0.1.9
	* added duration in play file
* 20200928, v0.1.10
	* configurable sounds directory
* 20200929, v0.1.11
	* edits on replaying media
* 20200929, v0.1.12
	* add replay for GoogleDevice
