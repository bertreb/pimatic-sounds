module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  http = require('http')
  fs = require('fs')
  path = require('path')
  _ = require('lodash')
  M = env.matcher
  Os = require('os')
  ping = require ("ping")
  Device = require('castv2-client').Client
  DefaultMediaReceiver = require('castv2-client').DefaultMediaReceiver
  Sonos = require('sonos').Sonos
  SonosDiscovery = require('sonos')
  #mdns = require('mdns')

  class SoundsPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>

      @soundsDir = path.resolve @framework.maindir, '../..', 'sounds'
      @pluginDir = path.resolve @framework.maindir, "../pimatic-sounds"

      @initFilename = "initSound.mp3"
      if !fs.existsSync(@soundsDir)
        env.logger.debug "Dir " + @soundsDir + " doesn't exist, is created"
        fs.mkdirSync(@soundsDir)
      else
        fullFilename = @soundsDir + "/" + @initFilename
        unless fs.existsSync(fullFilename)
          sourceInitFullfinename = @pluginDir + "/" + @initFilename
          fs.copyFile sourceInitFullfinename, fullFilename, (err) =>
            if err
              env.logger.error "InitSounds not copied " + err
            env.logger.debug "InitSounds copied to sounds directory"

      @serverPort = @config.port ? 8088
      @server = http.createServer((req, res) =>
        fs.readFile @soundsDir + "/" + req.url, (err, data) ->
          if err
            res.writeHead 404
            res.end JSON.stringify(err)
            return
          res.writeHead 200, {'Content-Type': 'audio/mpeg'}
          res.end data
          return
        return
      ).listen(@serverPort)

      process.on 'SIGINT', () =>
        if @server?
          @server.close()
          @server.removeAllListeners()
          env.logger.debug "Stopping plugin, closing server"

      oldClassName = "SoundsDevice"
      newClassName = "ChromecastDevice"
      for device,i in @framework.config.devices
        if device.class == oldClassName
          @framework.config.devices[i].class = newClassName
          env.logger.debug "Class '#{oldClassName}' of device '#{device.id}' migrated to #{newClassName}"

      pluginConfigDef = require './pimatic-sounds-config-schema'
      @configProperties = pluginConfigDef.properties

      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass('ChromecastDevice', {
        configDef: deviceConfigDef.ChromecastDevice,
        createCallback: (config, lastState) => new ChromecastDevice(config, lastState, @framework, @)
      })
      @framework.deviceManager.registerDeviceClass('SonosDevice', {
        configDef: deviceConfigDef.SonosDevice,
        createCallback: (config, lastState) => new SonosDevice(config, lastState, @framework, @)
      })
      @soundsClasses = ["ChromecastDevice","SonosDevice"]
      @framework.ruleManager.addActionProvider(new SoundsActionProvider(@framework, @soundsClasses, @soundsDir))

      @framework.deviceManager.on('discover', (eventData) =>
        @framework.deviceManager.discoverMessage 'pimatic-sounds', 'Not yet implemented' # Searching for new devices'
        ###
        SonosDiscovery.DeviceDiscovery((device) =>
          #env.logger.info "Sonos Device found with IP " +  device.host
          if not inConfigIp(device.host,"SonosDevice")
            newId = "sonos_" + device.host.split('.').join("")
            config =
              id: newId
              name: newId
              class: "SonosDevice"
              ip: device.host
            @framework.deviceManager.discoveredDevice( "pimatic-sounds", config.name, config)
        )
        scanner = mdns.createBrowser(mdns.tcp('googlecast'),
          {resolverSequence: mdns.Browser.defaultResolverSequence})
        scanner.on('serviceUp', (service) =>
          name = service.txtRecord.fn
          ip = service.addresses[0]
          if not inConfigIp(ip , "ChromecastDevice")
            if name?
              newId = name.replace(" ","_")
            else
              newId = "cast_" + ip.split('.').join("")
            config =
              id: newId
              name: newId
              class: "ChromecastDevice"
              ip: ip
            @framework.deviceManager.discoveredDevice( "pimatic-sounds", config.name, config)
        )
        scanner.start()
        setTimeout (=> scanner.stop()), 15000
        ###
      )

      inConfigIp = (deviceIP, cn) =>
        for device in @framework.deviceManager.devicesConfig
          if device.ip?
            if ((device.ip).indexOf(String deviceIP) >= 0) and device.class == cn
              env.logger.info "device " + deviceIP + " (" + cn + ") already in config"
              return true
        return false


  class ChromecastDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return
      @deviceStatus = off
      @textFilename = @id + "_text.mp3"

      #
      # Configure attributes
      #
      @attributes = {}
      @attributeValues = {}
      _attrs = ["status","info"]
      for _attr in _attrs
        @attributes[_attr] =
          description: "The " + _attr
          type: "string"
          label: _attr
          acronym: _attr
        @attributeValues[_attr] = ""
        @_createGetter(_attr, =>
          return Promise.resolve @attributeValues[_attr]
        )
        @setAttr _attr, @attributeValues[_attr]
      @setAttr("status","starting")

      #
      # Check if Device is online
      #
      @ip = @config.ip
      @onlineChecker = () =>
        env.logger.debug "Check online status device '#{@id}"
        ping.promise.probe(@ip,{timeout: 2})
        .then((host)=>
          if host.alive
            startupTime = () =>
              env.logger.debug "Device '#{@id}' is online"
              @deviceStatus = on
              @setAttr("status","online")
              if @server?
                @server.close()
              @initSounds()
            @startupTimer = setTimeout(startupTime,5000)
          else
            @deviceStatus = off
            @setAttr("status","offline")
            env.logger.error "Device '#{@id}' offline"
            @onlineCheckerTimer = setTimeout(@onlineChecker,30000)
        )
      @onlineChecker()

      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      for i, addresses of Os.networkInterfaces()
        for add in addresses
          if add.address.startsWith('192.168.')
            @serverIp = add.address
            env.logger.debug "Found IP adddress: " + @serverIp
      unless @serverIp?
        throw new Error "No IP address found!"

      #
      # The mediaserver and text settings and start of media server
      #
      @textFilename = @id + "_text.mp3"
      @serverPort = @plugin.config.port ? 8088
      @mainVolume = 0.40
      @initVolume = 0.40
      @soundsDir = @plugin.soundsDir
      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @media =
        url: baseUrl + "/" + @textFilename
        base: baseUrl
        filename: @textFilename

      #
      # The sounds states setup
      #
      @announcement = false
      @devicePlaying = false
      @deviceReplaying = false
      @devicePlayingUrl = ""
      @deviceReplayingUrl = ""

      #
      # The chromecast setup
      #
      @gaDevice = new Device()
      @gaDevice.connect(@ip, (err) =>
        if err?
          env.logger.error "Connect error " + err.message
          return
        @deviceStatus = on
        env.logger.info "Device connected"
        #
        # The chromecast player device
        #
        @gaDevice.launch(DefaultMediaReceiver, (err, app) =>
          if err?
            env.logger.error "Join error " + err.message
            return
          env.logger.debug "Starting player 2... " + app
          @_devicePlayer = app
          if @config.playInit or !(@config.playInit?)
            @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume)
          @_devicePlayer.on 'status player device', (status) =>
            #env.logger.info "PlayerStatus =======> " + JSON.stringify(status.transportId,null,2)
        )

        @gaDevice.getStatus((err, status)=>
          if err?
            env.logger.error "Client status error " + err
            return
        )

        @gaDevice.on 'error', (err) =>
          @deviceStatus = off
          env.logger.debug "Error in gaDevice " + err.message
          if gaDevice? then @gaDevice.close()
          @destroy()
          @onlineChecker()

        @gaDevice.on 'status', (status) =>
          #
          # get volume
          #
          if status.volume?.level
            @devicePlayingVolume = status.volume.level
            @mainVolume = @devicePlayingVolume
            env.logger.debug "New volume level ====> " + @devicePlayingVolume

          @gaDevice.getSessions((err,sessions) =>
            if err?
              env.logger.error "Error getSessions " + err.message
              return
            if sessions.length > 0
              firstSession = sessions[0]
              if firstSession.transportId?
                #
                # Join the chromecast info device
                #
                @gaDevice.join(firstSession, DefaultMediaReceiver, (err, app) =>
                  if err?
                    env.logger.error "Join error " + err.message
                    return
                  @_deviceInfo = app
                  @_deviceInfo.on 'status' , (status) =>
                    title = status?.media?.metadata?.title
                    contentId = status?.media?.contentId
                    if status.playerState is "IDLE" and @devicePlaying isnt false
                      @devicePlaying = false
                      if status.idleReason is "FINISHED"
                        if @annoucement and @deviceReplaying
                          @restartPlaying(@deviceReplayingUrl,@deviceReplayingVolume)
                          @setAttr "status", "restart"
                          @setAttr "info", @deviceReplayingInfo
                        if @annoucement
                          @setAttr "status", "idle"
                          @setAttr "info", ""
                          @annoucement = false
                          @deviceReplaying = false
                          #set volume back to mainVolume
                          @setVolume(@deviceReplayingVolume)
                          .then(()=>
                            env.logger.debug "Volume set back to presound value "
                          ).catch((err)=>
                            env.logger.debug "Niet gelukt volume terug te zetten op oude waarde"
                          )
                      else
                        @setAttr "status", "idle"
                        @setAttr "info", ""
                    else if status.playerState is "PLAYING" and @devicePlaying isnt true
                      @devicePlaying = true
                      if contentId
                        if (status.media.contentId).startsWith("http")
                          @devicePlayingUrl = status.media.contentId
                      @devicePlayingInfo = (if status?.media?.metadata?.artist then status.media.metadata.artist else "")
                      if @annoucement
                        @setAttr "status", "announcement"
                        @setAttr "info", @devicePlayingUrl
                      else
                        @setAttr "status", "playing"
                        @setAttr "info", @devicePlayingUrl
                )
          )
      )

    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol) =>
      return new Promise((resolve,reject) =>
        unless @gaDevice?
          reject("Device not online")
        @deviceReplayingUrl = @devicePlayingUrl
        @deviceReplayingInfo = @devicePlayingInfo
        @deviceReplayingVolume = @devicePlayingVolume
        if @devicePlaying
          @deviceReplaying = true
        media =
          contentId : _url
          contentType: 'audio/mpeg'
          streamType: 'BUFFERED'
        @gaDevice.launch(DefaultMediaReceiver, (err, app) =>
          if err?
            env.logger.error "Join error " + err.message
            return
          @_devicePlayer = app
          @setVolume(_vol)
          .then(()=>
            app.load(media, {autoplay:true}, (err,status) =>
              if err?
                env.logger.error 'error: ' + err
                reject(err)
              @annoucement = true
              env.logger.debug 'Playing annoucement ' + _url
              resolve()
            )
          )
        )
      )

    restartPlaying: (_url, _vol) =>
      return new Promise((resolve,reject) =>
        media =
          contentId : _url
          contentType: 'audio/mpeg'
          streamType: 'BUFFERED'
        @gaDevice.launch(DefaultMediaReceiver, (err, app) =>
          if err?
            env.logger.error "Join error " + err.message
            return
          @_devicePlayer = app
          @setVolume(_vol)
          .then(()=>
            app.load(media, {autoplay:true}, (err,status) =>
              if err?
                env.logger.error 'error: ' + err
                reject(err)
              @annoucement = false
              env.logger.debug '(Re)playing ' + _url
              resolve()
            )
          )
        )
      )

    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        if vol > 1 then vol /= 100
        if vol < 0 then vol = 0
        @mainVolume = vol
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        @gaDevice.setVolume(data, (err) =>
          if err?
            reject(err)
          resolve()
        )
      )

    destroy: ->
      try
        if @gaDevice?
          #@gaDevice.close()
          @gaDevice.removeAllListeners()
          @gaDevice = null
      catch err
        env.logger.error "Error in destroy " + err
      clearTimeout(@onlineCheckerTimer)
      clearTimeout(@startupTimer)
      super()

  class SonosDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return
      @deviceStatus = off
      @textFilename = @id + "_text.mp3"

      #
      # Configure attributes
      #
      @attributes = {}
      @attributeValues = {}
      _attrs = ["status","info"]
      for _attr in _attrs
        @attributes[_attr] =
          description: "The " + _attr
          type: "string"
          label: _attr
          acronym: _attr
        @attributeValues[_attr] = ""
        @_createGetter(_attr, =>
          return Promise.resolve @attributeValues[_attr]
        )
        @setAttr _attr, @attributeValues[_attr]
      @setAttr("status","starting")

      #
      # Check if Device is online
      #
      @ip = @config.ip
      @onlineChecker = () =>
        env.logger.debug "Check online status device '#{@id}"
        ping.promise.probe(@ip,{timeout: 2})
        .then((host)=>
          if host.alive
            startupTime = () =>
              env.logger.debug "Device '#{@id}' is online"
              @deviceStatus = on
              @setAttr("status","online")
              if @server?
                @server.close()
              @initSounds()
            @startupTimer = setTimeout(startupTime,5000)
          else
            @deviceStatus = off
            @setAttr("status","offline")
            env.logger.error "Device '#{@id}' offline"
            @onlineCheckerTimer = setTimeout(@onlineChecker,30000)
        )
      @onlineChecker()


      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      for i, addresses of Os.networkInterfaces()
        for add in addresses
          if add.address.startsWith('192.168.')
            @serverIp = add.address
            env.logger.debug "Found IP adddress: " + @serverIp
      unless @serverIp?
        throw new Error "No IP address found!"

      #
      # The mediaserver and text settings and start of media server
      #
      @textFilename = @id + "_text.mp3"
      @serverPort = @plugin.config.port ? 8088
      @mainVolume = 40
      @initVolume = 40
      @soundsDir = @plugin.soundsDir
      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @media =
        url: baseUrl + "/" + @textFilename
        base: baseUrl
        filename: @textFilename

      #
      # The sounds states setup
      #
      @announcement = false
      @devicePlaying = false
      @deviceReplaying = false
      @devicePlayingUrl = ""
      @deviceReplayingUrl = ""

      #
      # The sonos setup
      #
      @sonosDevice = new Sonos(@ip)

      if @config.playInit or !(@config.playInit?)
        @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume)

      @sonosDevice.on 'PlayState', (state) =>
        env.logger.debug 'The PlayState changed to ' + state
        if state is "PLAYING"
          @devicePlaying = true
        else
          @devicePlaying = false
        @setAttr("status",state)
        @sonosDevice.currentTrack()
        .then((track) =>
          env.logger.debug 'Current track ' + JSON.stringify(track,null,2)
          @setAttr("info",track.title)
        )

      @sonosDevice.on 'Volume', (volume) =>
        env.logger.debug 'Volume changed to ' + volume
        @mainVolume = volume

      @sonosDevice.on 'Mute', (isMuted) =>
        env.logger.debug 'Mute changed to ' + isMuted


    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol) =>
      return new Promise((resolve,reject) =>
        unless @sonosDevice?
          reject("Device not online")
        media =
          uri : _url
          onlyWhenPlaying: false
          volume: _vol
        @sonosDevice.playNotification(media)
        .then((result) =>
          env.logger.debug 'Playing annoucement ' + result
          resolve()
        ).catch((err)=>
          env.logger.error 'error: ' + err
          reject(err)
        )
      )

    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        if vol > 1 then vol /= 100
        if vol < 0 then vol = 0
        @mainVolume = vol
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        @sonosDevice.setVolume(data, (err) =>
          if err?
            reject(err)
          resolve()
        )
      )

    destroy: ->
      try
        if @sonosDevice?
          @sonosDevice.stop()
       catch err
        env.logger.error "Error in Sonos destroy " + err
      clearTimeout(@onlineCheckerTimer)
      clearTimeout(@startupTimer)
      super()


  class SoundsActionProvider extends env.actions.ActionProvider

    constructor: (@framework, @soundsClasses, @dir) ->
      @root = @dir
      @mainVolume = 20

    _soundsClasses: (_cl) =>
      for _soundsClass in @soundsClasses
        if _cl is _soundsClass
          return true
      return false

    parseAction: (input, context) =>
      soundsDevices = _(@framework.deviceManager.devices).values().filter(
        (device) => @_soundsClasses(device.config.class)
      ).value()
      text = ""
      soundsDevice = null
      match = null
      volume = null
      soundType = ""

      setText = (m, txt) =>
        if txt is null or txt is ""
          context?.addError("No text")
          return
        soundType = "text"
        text = txt
        return

      setLogString = (m, tokens) =>
        soundType = "text"
        text = tokens
        return

      setFilename = (m, filename) =>
        fullfilename = path.join(@root, filename)
        try
          stats = fs.statSync(fullfilename)
          if stats.isFile()
            text = filename
            soundType = "file"
            return
          else if stats.isDirectory()
            context?.addError("'" + fullfilename + "' is a directory")
            return
          else
            context?.addError("File " + fullfilename + "' does not excist")
            return
        catch err
          context?.addError("File " + fullfilename + "' does not excist")
          return

      setMainVolume = (m, vol) =>
        if vol < 0
          context?.addError("Minimum volume is 0")
          return
        if vol > 100
          context?.addError("Maximum volume is 100")
          return
        @mainVolume = vol
        return

      setVolume = (m, vol) =>
        if vol < 0
          context?.addError("Minimum volume is 0")
          return
        if vol > 100
          context?.addError("Maximum volume is 100")
          return
        volume = vol
        return

      m = M(input, context)
        .match('play ')
        .or([
          ((m) =>
            return m.match('text ', optional: yes)
              .matchStringWithVars(setLogString)
          ),
          ((m) =>
            return m.match('file ', optional: yes)
              .matchString(setFilename)
          ),
          ((m) =>
            return m.match('vol ', optional: yes)
              .matchNumber(setMainVolume)
              .match(' on ')
              .matchDevice(soundsDevices, (m, d) ->
                # Already had a match with another device?
                if soundsDevice? and soundsDevice.id isnt d.id
                  context?.addError(""""#{input.trim()}" is ambiguous.""")
                  return
                soundType = "vol"
                soundsDevice = d
                match = m.getFullMatch()
              )
          )
        ])
        .or([
          ((m) =>
            return m.match(' vol ', optional: yes)
              .matchNumber(setVolume)
              .match(' on ')
              .matchDevice(soundsDevices, (m, d) ->
                # Already had a match with another device?
                if soundsDevice? and soundsDevice.id isnt d.id
                  context?.addError(""""#{input.trim()}" is ambiguous.""")
                  return
                soundsDevice = d
                match = m.getFullMatch()
              )
          ),
          ((m) =>
            return m.match(' on ')
              .matchDevice(soundsDevices, (m, d) ->
                # Already had a match with another device?
                if soundsDevice? and soundsDevice.id isnt d.id
                  context?.addError(""""#{input.trim()}" is ambiguous.""")
                  return
                soundsDevice = d
                match = m.getFullMatch()
              )
          )
        ])

      unless volume?
        volume = @mainVolume

      if match? # m.hadMatch()
        env.logger.debug "Rule matched: '", match, "' and passed to Action handler"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new SoundsActionHandler(@framework, @, text, soundType, soundsDevice, volume)
        }
      else
        return null


  class SoundsActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @actionProvider, @textIn, @soundType, @soundsDevice, @volume) ->

    executeAction: (simulate) =>
      if simulate
        return __("would save file \"%s\"", @text)
      else
        if @soundsDevice.deviceStatus is off
          return __("\"%s\" Rule not executed device offline", @text)
        try
          switch @soundType
            when "text"
              @framework.variableManager.evaluateStringExpression(@textIn).then( (strToLog) =>
                @text = strToLog
                env.logger.debug "Creating sound file... with text: " + @text
                @soundsDevice.gtts.save(@soundsDevice.soundsDir + "/" + @soundsDevice.textFilename, @text, (err) =>
                  if err?
                    return __("\"%s\" was not generated", @text)
                  env.logger.debug "Sound generated, now casting " + @soundsDevice.media.url
                  @soundsDevice.playAnnouncement(@soundsDevice.media.url, Number @volume)
                  .then(()=>
                    env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + @volume
                    return __("\"%s\" was played ", @text)
                  ).catch((err)=>
                    env.logger.debug "Error in playAnnouncement: " + err
                    return __("\"%s\" was not played", @text)
                  )
                )
              )
            when "file"
              fullFilename = (@soundsDevice.media.base + "/" + @text)
              env.logger.debug "Playing sound file... " + fullFilename
              @soundsDevice.playAnnouncement(fullFilename, Number @volume)
              .then(()=>
                env.logger.debug 'Playing ' + fullFilename + " with volume " + @volume
                return __("\"%s\" was played ", @text)
              ).catch((err)=>
                env.logger.debug "Error in playAnnouncement: " + err
                return __("\"%s\" was not played", @text)
              )
            when "vol"
              @soundsDevice.setVolume((Number @volume), (err) =>
                if err?
                  env.logger.debug "Error setting volume " + err
                  return __("\"%s\" was played but volume was not set", @text)
                return __("\"%s\" was played with volume set", @text)
              )
            else
              env.logger.debug 'error: unknown playtype'
              return __("\"%s\" unknown playtype", @soundType)

          return __("\"%s\" executed", @text)
        catch err
          @soundsDevice.deviceStatus = off
          env.logger.debug "Device offline, start onlineChecker " + err
          @soundsDevice.onlineChecker()
          return __("\"%s\" Rule not executed device offline", @text) + err

  soundsPlugin = new SoundsPlugin
  return soundsPlugin
