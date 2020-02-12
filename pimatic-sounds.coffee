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
      @soundsClasses = ["ChromecastDevice"]
      @framework.ruleManager.addActionProvider(new SoundsActionProvider(@framework, @soundsClasses, @soundsDir))

  class ChromecastDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return
      @deviceStatus = off

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
      @server = http.createServer((req, res) =>
        fs.readFile @plugin.soundsDir + "/" + req.url, (err, data) ->
          if err
            res.writeHead 404
            res.end JSON.stringify(err)
            return
          res.writeHead 200, {'Content-Type': 'audio/mpeg'}
          res.end data
          return
        return
      ).listen(@serverPort)

      @server.on 'clientError', (err, socket) =>
        socket.end('HTTP/1.1 400 Bad Request\r\n\r\n')

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
        if @server?
          @server.close()
          @server.removeAllListeners()
        if @gaDevice?
          #@gaDevice.close()
          @gaDevice.removeAllListeners()
          @gaDevice = null
      catch err
        env.logger.error "Error in destroy " + err
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
              .matchString(setText)
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

    constructor: (@framework, @actionProvider, @text, @soundType, @soundsDevice, @volume) ->

    executeAction: (simulate) =>
      if simulate
        return __("would save file \"%s\"", @text)
      else
        #__("\"%s\" was ok for now", @text)
        #return
        try
          #if @soundsDevice.deviceStatus is off
          #  return __("\"%s\" Rule not executed device offline", @text)
          switch @soundType
            when "text"
              env.logger.debug "Creating sound file... with text: " + @text
              @soundsDevice.gtts.save(@soundsDevice.soundsDir + "/" + @soundsDevice.textFilename, @text, (err) =>
                if err?
                  return __("\"%s\" was not generated", @text)
                env.logger.debug "Sound generated, now casting " + @soundsDevice.media.url
                @soundsDevice.playAnnouncement(@soundsDevice.media.url, Number @volume/100)
                .then(()=>
                  if err?
                    env.logger.error 'error: ' + err
                    return __("\"%s\" was not played", @text)
                  env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + @volume
                ).catch((err)=>
                  env.logger.error "Error in playAnnouncement: " + err
                )
              )
            when "file"
              fullFilename = (@soundsDevice.media.base + "/" + @text)
              env.logger.debug "Playing sound file... " + fullFilename
              @soundsDevice.playAnnouncement(fullFilename, Number @volume/100, (err) =>
                if err?
                  env.logger.error 'error: ' + err
                  return __("\"%s\" was not played", err)
                env.logger.debug 'Playing ' + fullFilename + " with volume " + @volume
              )
            when "vol"
              @soundsDevice.setVolume((Number @volume/100), (err) =>
                if err?
                  env.logger.error "Error setting volume " + err
                  return __("\"%s\" was played but volume was not set", @text)
                return __("\"%s\" was played with volume set", @text)
              )
            else
              env.logger.error 'error: unknown playtype'
              return __("\"%s\" unknown playtype", @soundType)

          return __("\"%s\" executed", @text)
        catch err
          @soundsDevice.deviceStatus = off
          env.logger.debug "Device offline, start onlineChecker " + err
          @soundsDevice.onlineChecker()
          return __("\"%s\" Rule not executed device offline", @text) + err

  soundsPlugin = new SoundsPlugin
  return soundsPlugin
