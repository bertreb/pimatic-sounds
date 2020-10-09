module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  http = require('http')
  fs = require('fs')
  path = require('path')
  _ = require('lodash')
  M = env.matcher
  milliseconds = env.milliseconds
  Os = require('os')
  ping = require("ping")
  Device = require('castv2-client').Client
  DefaultMediaReceiver = require('castv2-client').DefaultMediaReceiver
  Sonos = require('sonos').Sonos
  SonosDiscovery = require('sonos')
  util = require('util')
  getContentType = require('./content-types.js')
  bonjour = require('bonjour')()
  needle = require('needle')
  #ps = require 'python-shell'
  childProcess = require("child_process")

  exec = (command) ->
    return new Promise( (resolve, reject) ->
      childProcess.exec(command, (err, stdout, stderr) ->
        if err
          err.stdout = stdout.toString() if stdout?
          err.stderr = stderr.toString() if stderr?
          return reject(err)

        #_result = toJson(stdout)
        return resolve({stdout: stdout.toString(), stderr: stderr.toString()}) # {stdout: stdout, stderr: stderr})
      )
    )

  ###

  toJson = (str) ->
    result = {}
    lines = str.split('\n')
    if lines.length < 1
      return str
    for line in lines
      _index = line.indexOf(":")
      _key = line.substring(0,_index).trim().toLowerCase()
      result[_key] = ""
      _value = line.substring(_index+1,line.length).trim().toLowerCase()
      unless _value is ""
        unless Number.isNaN(Number _value)
          _value = Number _value
        if (String _value).toLowerCase() in ["false","true"]
          _value =  Boolean (String _value).toLowerCase()
        if (String _value).toLowerCase() in ["none"]
          _value =  null
        if (String _value).length >= 2
          _valueStripped = String _value # (String _value).substring(1, (String _value).length-1)
          env.logger.debug "_valueStripped " + _valueStripped
          if _valueStripped is "{}"
            _value =  {}
          else if _valueStripped is "[]"
            _value = []

        result[_key] = _value
    return result
  ###

  class SoundsPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>

      defaultSounds = @config.soundsDirectory ? 'sounds'
      @soundsDir = path.resolve @framework.maindir, '../..', defaultSounds
      @pluginDir = path.resolve @framework.maindir, "../pimatic-sounds"
      @pimaticDir = path.resolve @framework.maindir, '../..'



      @initFilename = "initSound.mp3"
      if !fs.existsSync(@soundsDir)
        env.logger.debug "Dir " + @soundsDir + " doesn't exist, is created"
        fs.mkdirSync(@soundsDir)
      fullFilename = @soundsDir + "/" + @initFilename
      unless fs.existsSync(fullFilename)
        sourceInitFullfinename = @pluginDir + "/" + @initFilename
        fs.copyFile sourceInitFullfinename, fullFilename, (err) =>
          if err
            env.logger.error "InitSounds not copied " + err
          env.logger.debug "InitSounds copied to sounds directory"

      # init text to speech
      switch @config.tts
        when "google-cloud"
          language = @config.language ? "en-US"
          voice = @config.voice ? ""
          pitch = 0
          pitch = @config.pitch if (@config.pitch >= -20) and (@config.pitch <= 20)
          speakingRate = 1
          speakingRate = @config.speakingRate if (@config.speakingRate >= 0.25) and (@config.speakingRate <= 4)
          options = 
            language: language
            voice: voice
            pitch: pitch
            speakingRate: speakingRate
          fs.readFile @pimaticDir + "/" + @config.googleCloudJson, (err, data) =>
            if err
              env.logger.debug "Error, Google Cloud Json not found. Using google-translate."
              @language = @config.language ? "en"
              @gtts = require('node-gtts')(language)
            else
              _data = JSON.parse(data)
              cred =
                email: _data.client_email
                private_key: _data.private_key
              @gtts = require('./google-speech.js')(cred, options)
        else
          @language = @config.language ? "en"
          @gtts = require('node-gtts')(@language)

      # detect own IP address
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
      @mainVolume = 20
      @initVolume = 40
      baseUrl = "http://" + @serverIp + ":" + @serverPort

      @serverPort = if @config.port? then @config.port else 8088
      @server = http.createServer((req, res) =>
        fs.readFile @soundsDir + "/" + req.url, (err, data) ->
          if err
            res.writeHead 404
            res.end JSON.stringify(err)
            return
          contentType = getContentType(req.url)
          res.writeHead 200, {'Content-Type': contentType} #'audio/mpeg'}
          res.end data
          return
        return
      ).listen(@serverPort)

      process.on 'SIGINT', () =>
        if @server?
          @server.close()
          @server.removeAllListeners()
        if @browser?
          @browser.stop()
        clearTimeout(@discoveryTimer)
        #if bonjour?
        #  bonjour.destroy()
        env.logger.debug "Stopping plugin, closing server"
        process.exit()

      pluginConfigDef = require './pimatic-sounds-config-schema'
      @configProperties = pluginConfigDef.properties

      deviceConfigDef = require("./device-config-schema")

      oldClassName = "SoundsDevice"
      newClassName = "ChromecastDevice"
      @soundsClasses = ["ChromecastDevice","SonosDevice"]
      @soundsAllClasses = ["ChromecastDevice","GoogleDevice","SonosDevice","GroupDevice"]
      @enumSoundsDevices = []
      @defaultChromecastPort = 8009
      env.logger.debug "Found enum SoundsGroups: " + @enumSoundsGroups
      for device,i in @framework.config.devices
        className = device.class
        #convert SoundsDevice to new ChromecastDevice
        if className == oldClassName
          @framework.config.devices[i].class = newClassName
          env.logger.debug "Class '#{oldClassName}' of device '#{device.id}' migrated to #{newClassName}"
        # Add @enumSoundsDevices per SoundsGroup device
        if _.find(@soundsClasses,(c) => c.indexOf(device.class)>=0)
          unless _.find(@enumSoundsDevices, (d)=> d.name == device.id)
            deviceConfigDef["GroupDevice"].properties.devices.items.properties.name["enum"].push device.id
        #Add default portnumber for ChromecastDevices
        if (device.class).indexOf("ChromecastDevice")>=0
          unless device.port?
            @framework.config.devices[i]["port"] = @defaultChromecastPort

      @framework.on 'deviceAdded', (device) =>
        if _.find(@soundsClasses,(c) => c.indexOf(device.class)>=0)
          #_enumSoundsDevices = deviceConfigDef["GroupDevice"].properties.devices.items.properties.name["enum"]
          env.logger.debug "New Sounds device added to Group enum"
          unless _.find(@enumSoundsDevices, (d)=> d.name == device.id)
            deviceConfigDef["GroupDevice"].properties.devices.push device.id
      @framework.on 'deviceRemoved', (device) =>
        if _.find(@soundsClasses,(c) => c.indexOf(device.class)>=0)
          #_enumSoundsDevicesTemp = deviceConfigDef["GroupDevice"].properties.devices.items.properties.name["enum"]
          _soundsDevices = _.pull(deviceConfigDef["GroupDevice"].properties.devices, device.id)
          env.logger.debug "SoundsDevice '#{_device.config.id}' device removed from Group Devices: " + _soundsDevices
          deviceConfigDef["GroupDevice"].properties.devices = _soundsDevices
      ###
      @framework.on 'deviceChanged', (device) =>
        if _.find(["GroupDevice"],(c) => c.indexOf(device.class)>=0)
          # update devices list in GroupPlugin

          env.logger.debug "SoundsDevice '#{_device.config.id}' device changed"
          #deviceConfigDef["GroupDevice"].properties.devices.items.properties.name["enum"] = _enumSoundsDevices
      ###

      @framework.deviceManager.registerDeviceClass('ChromecastDevice', {
        configDef: deviceConfigDef.ChromecastDevice,
        createCallback: (config, lastState) => new ChromecastDevice(config, lastState, @framework, @)
      })
      @framework.deviceManager.registerDeviceClass('GoogleDevice', {
        configDef: deviceConfigDef.GoogleDevice,
        createCallback: (config, lastState) => new GoogleDevice(config, lastState, @framework, @)
      })
      @framework.deviceManager.registerDeviceClass('SonosDevice', {
        configDef: deviceConfigDef.SonosDevice,
        createCallback: (config, lastState) => new SonosDevice(config, lastState, @framework, @)
      })

      @framework.deviceManager.registerDeviceClass('GroupDevice', {
        configDef: deviceConfigDef.GroupDevice,
        createCallback: (config, lastState) => new GroupDevice(config, lastState, @framework, @)
      })

      @framework.ruleManager.addActionProvider(new SoundsActionProvider(@framework, @soundsAllClasses, @soundsDir))

      @framework.deviceManager.on('discover', (eventData) =>
        @framework.deviceManager.discoverMessage 'pimatic-sounds', 'Searching for new devices'

        SonosDiscovery.DeviceDiscovery((device) =>
          #env.logger.info "Sonos Device found with IP " +  device.host
          if not ipInConfig(device.host, null, "SonosDevice")
            newId = "sonos_" + device.host.split('.').join("")
            config =
              id: newId
              name: newId
              class: "SonosDevice"
              ip: device.host
            @framework.deviceManager.discoveredDevice( "pimatic-sounds", config.name, config)
        )
        discoverChromecastDevices()
      )

      discoverChromecastDevices = () =>
        @browser = bonjour.find({type: 'googlecast'}, (service) =>
          for address in service.addresses
            if address.split('.').length == 4
              @allreadyInConfig = false
              env.logger.debug "Found ip: " + address + ", port: " + service.port + ", friendlyName: " + service.txt.fn
              friendlyName = service.txt.fn
              checkId = (service.txt.md).replace(/\s+/g, '_') + "_" + friendlyName
              device = @framework.deviceManager.getDeviceById(service.txt.id)
              if device?
                @allreadyInConfig = true
                env.logger.info "device '" + device.config.name + "' already in config"
                if address.indexOf(device.config.ip)<0 or service.port != device.config.port
                  config =
                    id: device.config.id
                    name: device.config.name
                    ip: address
                    class: device.config.class
                    port: service.port
                    playInit: device.config.playInit
                  env.logger.debug "device '" + device.config.name + "' ip and port updated"
                  device.setOpts(address, service.port)

              if not @allreadyInConfig
                if service.txt.md?
                  if friendlyName?
                    newName = service.txt.md + " - " + friendlyName
                    newId = checkId
                  else
                    newName = service.txt.md + "_" + address.split('.').join("") + " - " + service.port
                    newId = (service.txt.md).replace(/\s+/g, '_') + "_" + address.split('.').join("") + "-" + service.port
                else
                  newName = "cast " + address.split('.').join("") + " - " + service.port
                  newId = "cast_" + address.split('.').join("") + "-" + service.port
                if @config.assistantRelay
                  _cl = "GoogleDevice"
                else
                  _cl = "ChromecastDevice"
                config =
                  id: service.txt.id
                  name: newName
                  class: _cl
                  ip: address
                  port: service.port
                @framework.deviceManager.discoveredDevice( "pimatic-sounds", config.name, config)
              else
                env.logger.info "Device already in config"
        )
        @discoveryTimer = setTimeout(=>
          @browser.stop()
          env.logger.info "Sounds discovery stopped"
        , 20000)



      ipInConfig = (deviceIP, devicePort, cn) =>
        for device in @framework.deviceManager.devicesConfig
          if device.ip?
            if ((device.ip).indexOf(String deviceIP) >= 0) and cn.indexOf(device.class)>=0
              if device.port?
                if Number device.port == Number devicePort
                  #env.logger.info "device '" + device.name + "' already in config"
                  return true
              else
                #env.logger.info "device '" + device.name + "' already in config"
                return true
        return false


  class ChromecastDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return

      if @plugin.config.assistantRelay 
        @assistantRelay = true
      else
        @assistantRelay = false

      @assistantRelayIp = @plugin.config.assistantRelayIp
      @assistantRelayPort = @plugin.config.assistantRelayPort ? 3000
      @assistantRelayUser = @plugin.config.assistantRelayUser


      @deviceStatus = off
      @deviceReconnecting = false
      @textFilename = @id + "_text.mp3"

      @current =
        url: ""
        volume: 0


      #
      # Configure attributes
      #
      @attributes = {}
      @attributeValues = {}
      _attrs = ["status","info", "volume"]
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
      @port = (if @config.port? then @config.port else 8009) # default single device port
      @heatbeatTime = 300000 # 5 minutes heartbeat
      @onlineChecker = () =>
        env.logger.debug "Heartbeat check online status device '#{@id}"
        ping.promise.probe(@ip,{timeout: 2})
        .then((host)=>
          if host.alive
            if @deviceStatus is on
              # status checked and device is online no action, schedule next heartbeat
              @onlineCheckerTimer = setTimeout(@onlineChecker,@heatbeatTime)
              return
            startupTime = () =>
              env.logger.debug "Device '#{@id}' is online"
              @deviceStatus = on
              @setAttr("status","idle")
              @setAttr("info","")
              @initSounds()
            @startupTimer = setTimeout(startupTime,20000)
          else
            #@deviceStatus = off
            @setAttr("status","offline")
            env.logger.debug "Device '#{@id}' offline"
          @onlineCheckerTimer = setTimeout(@onlineChecker,@heatbeatTime)
        )
        .catch((err)=>
          env.logger.debug "Error pinging #{@ip} " + err
        )

      @framework.variableManager.waitForInit()
      .then(()=>
        @onlineChecker()
      )
      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @gtts = @plugin.gtts
      ###
      switch @plugin.config.tts
        when "google-cloud"
          @language = @plugin.config.language ? "en-US"
          fs.readFile @plugin.pluginDir + "/" + @plugin.config.googleCloudJson, (err, data) =>
            if err
              env.logger.error "Error, no Google Cloud Json found!"
              return
            _data = JSON.parse(data);
            @cred =
              email: _data.client_email
              private_key: _data.private_key
            @gtts = require('./google-speech.js')(@language, @cred)
        else
          @language = @plugin.config.language ? "en"
          @gtts = require('node-gtts')(@language)
      ###

      @mainVolume = 20
      @initVolume = 40

      @serverPort = @plugin.serverPort
      @serverIp = @plugin.serverIp
      @soundsDir = @plugin.soundsDir
      @baseUrl = "http://" + @serverIp + ":" + @serverPort
      @textFilename = @id + "_text.mp3"

      @media =
        url: @baseUrl + "/" + @textFilename
        base: @baseUrl
        filename: @textFilename

      #
      # The sounds states setup
      #
      @currentDeviceState = "idle"
      #@announcement = false
      @devicePlaying = false
      @devicePaused = false
      @deviceReplaying = false
      @devicePlayingUrl = ""
      @deviceReplayingUrl = ""
      @deviceReplayingPaused = false
      @devicePlayingVolume = @mainVolume

      #
      # The chromecast status listener setup
      #
      @statusDevice = new Device()
      @statusDevice.on 'error', (err) =>
        @deviceReconnecting = true
        if err.message.indexOf("ECONNREFUSED")
          env.logger.debug "Network config probably changed or device is offline"
        else if err.message.indexOf("ETIMEDOUT")
          env.logger.debug "StatusDevice offline"
        else
          env.logger.debug "Error in status device " + err.message

      # subscribe to inner client
      @statusDevice.client.on 'close', () =>
        @deviceStatus = off
        @deviceReconnecting = true
        env.logger.debug "StatusDevice Client Client closing"

      @ipCast = @assistantRelayIp + ':' + @assistantRelayPort + '/cast'
      @ipCastStop = @ipCast + '/stop'
      @ipAssistant = @assistantRelayIp + ':' + @assistantRelayPort + '/assistant'  

      opts =
        host: @ip
        port: @port
      env.logger.debug "Connecting to statusDevice with opts: " + JSON.stringify(opts,null,2)

      @opts =
        json: true
        headers: {'Content-Type': 'application/json;charset=UTF-8'}

      @bodyInit =
        device: @ip
        source: @media.base + "/" + @plugin.initFilename
        type: 'remote'
      @bodyAnnouncement = 
        command: "no text yet"
        broadcast: true
        user: @assistantRelayUser
      @bodyCast = 
        device: @ip
        source: @media.base + "/" + @plugin.initFilename
        type: 'remote'
      @bodyConvers =
        command: "tell a joke"
        converse: true
        user: @assistantRelayUser

      @statusDevice.connect(opts, (err) =>
        if err?
          env.logger.debug "Connect error " + err.message
          return
        @deviceStatus = on
        env.logger.info "Device '#{@name}' connected"

        if @config.playInit or !(@config.playInit?)
          unless @deviceReconnecting
            @setAnnouncement("init sounds")
            @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume, "init sounds", null)
            .then(()=>
            ).catch((err)=>
              env.logger.debug "playAnnouncement error handled " + err
            )

        @statusDevice.on 'status', (_status) =>

          if _status?.applications?
            if Boolean _status.applications[0].isIdleScreen
              @devicePlaying = false
              @devicePaused = false
              @deviceReplaying = false
              @devicePlayingUrl = ""
              @deviceReplayingUrl = ""
              @deviceReplayingPaused = false
              @setAttr "status", "idle"
              @setAttr "info", ""
              @setAttr("volume",@mainVolume)

          if _status.volume?.level?
            @devicePlayingVolume = Math.round(_status.volume.level * 100)
            @mainVolume = @devicePlayingVolume
            @setAttr("volume", @mainVolume)

          if @statusDevice?
            @statusDevice.getSessions((err,sessions) =>
              if err?
                env.logger.error "Error getSessions " + err.message
                return
              if sessions.length > 0
                firstSession = sessions[0]
                if firstSession.transportId?
                  @statusDevice.join(firstSession, DefaultMediaReceiver, (err, app) =>
                    if err?
                      env.logger.error "Join error " + err.message
                      return
                    app.on 'status' , (status) =>
                      #env.logger.info "Status update, media: " + JSON.stringify(status.media,null,2)
                      title = status?.media?.metadata?.title
                      contentId = status?.media?.contentId
                      if status.playerState is "PLAYING" or status.playerState is "BUFFERING" or status.playerState is "IDLE" or status.playerState is "PAUSED"
                        if contentId                          
                          if (status.media.contentId).startsWith(@announcementUrl)
                            @setAttr "status", "annoucement"
                            @setAttr "info", @getAnnouncement()
                            return
                          else                          
                            if (status.media.contentId).startsWith("http")
                              @devicePlayingUrl = status.media.contentId
                            else
                              @devicePlayingUrl = null
                            @devicePlayingInfo = (if status?.media?.metadata?.title then status.media.metadata.title else "")
                            @attributes["info"].label = String @devicePlayingInfo
                            if @devicePlayingInfo.length > 30
                              @devicePlayingInfo = ((@devicePlayingInfo.substr(0,30)) + " ...")
                            @devicePlayingMedia = status.media
                            @setAttr "info", @devicePlayingInfo
                            if status.media?.duration?
                              @duration = status.media.duration * 1000
                        @devicePlaying = if (status.playerState is "PLAYING" or status.playerState is "BUFFERING") then true else false
                        @devicePaused = if status.playerState is "PAUSED" then true else false
                        @setAttr "status", status.playerState.toLowerCase()
                        return
                      if status.playerState is "IDLE" and status.idleReason is "FINISHED"
                        @devicePlaying = false
                        @devicePaused = false
                        @setAttr "status", "idle"
                        @setAttr "info", ""
                        return
                      if status.playerState is "PAUSED"
                        #env.logger.debug "PlayerState is PAUSED"
                        @devicePlaying = true
                        @devicePaused = true
                        @setAttr "status", "paused"
                        @setAttr "info", ""
                        return
                  )
              else
                # sessions == 0
                @devicePlaying = false
                @devicePaused = false
                @setAttr "status", "idle"
                @setAttr "info", ""
            )
      )

    setOpts: (ip, port) =>
      @ip = ip
      @port = port

    setAttr: (attr, _status) =>
      unless @attributeValues[attr] is _status
        @attributeValues[attr] = _status
        @emit attr, @attributeValues[attr]
        #env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol, _text, _duration) =>
      return new Promise((resolve,reject) =>

        #@_volume = _vol * 100 if _vol < 1

        @announcement = true
        @announcementUrl = _url
        @deviceReplayingVolume = @devicePlayingVolume
        if @devicePlaying
          @deviceReplaying = true
          @deviceReplayingUrl = @devicePlayingUrl
          @deviceReplayingInfo = @devicePlayingInfo
          @deviceReplayingMedia = @devicePlayingMedia
          @deviceReplayingPaused = @devicePaused
          #env.logger.debug "Replaying values set, vol: " + @deviceReplayingVolume + ", url: " + @deviceReplayingUrl + ", paused: " + @devicePaused
        else
          @deviceReplaying = false
          @deviceReplayingUrl = null # @devicePlayingUrl


        device = new Device()

        device.on 'error', (err) =>
          if err.message.indexOf("ECONNREFUSED")
            env.logger.debug "Network config probably changed or device is offline"
          else if err.message.indexOf("ETIMEDOUT")
            env.logger.debug "PlayAnnouncementDevice offline"
          else
            env.logger.debug "Error in playAnnouncementDevice " + err.message

        # subscribe to inner client
        device.client.on 'close', () =>
          @deviceStatus = off
          env.logger.debug "PlayAnnouncement Client Client closing"

        opts =
          host: @ip
          port: @port

        #env.logger.debug "Connecting to gaDevice with opts: " + JSON.stringify(opts,null,2)
        device.connect(opts, (err) =>
          if err?
            env.logger.debug "Connect error " + err.message
            return
          @deviceStatus = on

          defaultMetadata =
            metadataType: 0
            title: "Pimatic Announcement"
            #posterUrl: "https://avatars0.githubusercontent.com/u/6502361?v=3&s=400"
            #images: [
            #  { url: "https://avatars0.githubusercontent.com/u/6502361?v=3&s=20" }
            #],
          media =
            contentId : _url
            contentType: getContentType(_url)
            streamType: 'BUFFERED'
            metadata: defaultMetadata

          duration = _duration

          try
            device.launch(DefaultMediaReceiver, (err, app) =>
              if err?
                env.logger.debug "Launch error " + err.message
                reject("Launch error")
                return
              unless app?
                reject("Launch error app is undefined")
                return
              app.on 'status', (status) =>
                if status.playerState is "IDLE" and status.idleReason is "FINISHED"
                  @setAttr "status", "idle"
                  @setAttr "info", ""
                
                  @stopCasting()
                  .then(() =>
                    env.logger.debug "Casting stopped"
                    @announcement = false      
                    if @deviceReplaying and @deviceReplayingUrl? and not (@deviceReplayingUrl is "")
                      env.logger.debug("@deviceReplaying " + (@deviceReplaying) + ", @deviceReplayingUrl: " + @deviceReplayingUrl + ", @deviceReplayingVolume " + @deviceReplayingVolume + ", paused: " + @deviceReplayingPaused)
                      @restartPlaying(@deviceReplayingUrl, @deviceReplayingVolume, @deviceReplayingPaused)
                      .then(()=>
                        env.logger.debug "Media restarted: " + @deviceReplayingUrl
                        resolve()
                        return
                      ).catch((err)=>
                        env.logger.debug "Error startReplaying " + err
                        @announcement = false
                        reject()
                        return
                      )
                  ).catch((err) =>
                    env.logger.error "Error in stopping casting: " + err
                    @announcement = false
                    reject()
                    return
                  )
        
              @setVolume(_vol)
              .then(()=>
                app.load(media, {autoplay:true}, (err,status) =>
                  @announcement = false
                  if err?
                    env.logger.debug 'Error handled in playing announcement: ' + err
                    @stopCasting()
                    .then(()=>
                      env.logger.debug("@deviceReplaying " + (@deviceReplaying) + ", @deviceReplayingUrl: " + @deviceReplayingUrl + ", @deviceReplayingVolume " + @deviceReplayingVolume + ", paused: " + @deviceReplayingPaused)                    
                      if @deviceReplaying and @deviceReplayingUrl? and not (@deviceReplayingUrl is "")
                        @restartPlaying(@deviceReplayingUrl, @deviceReplayingVolume, @deviceReplayingPaused)
                        .then(()=>
                          env.logger.debug "Media restarted: " + @deviceReplayingUrl
                          resolve()
                        ).catch((err)=>
                          env.logger.debug "Error startReplaying " + err
                          @announcement = false
                          reject()
                        )
                    ).catch((err)=> env.logger.debug "Error in restoring after announcement " + err)
                    resolve()
                    return
                  if duration?
                    env.logger.debug "Playing announcement on device '" + @id + ", duration " + duration
                    @durationTimer = setTimeout(() =>
                      @stopCasting()
                      .then(()=>
                        env.logger.debug("@deviceReplaying " + (@deviceReplaying) + ", @deviceReplayingUrl: " + @deviceReplayingUrl + ", @deviceReplayingVolume " + @deviceReplayingVolume + ", paused: " + @deviceReplayingPaused)                    
                        if @deviceReplaying and @deviceReplayingUrl? and not (@deviceReplayingUrl is "")
                          @restartPlaying(@deviceReplayingUrl, @deviceReplayingVolume, @deviceReplayingPaused)
                          .then(()=>
                            env.logger.debug "Media restarted: " + @deviceReplayingUrl
                            resolve()
                          ).catch((err)=>
                            env.logger.debug "Error startReplaying " + err
                            @announcement = false
                            reject()
                          )
                        else
                          @setVolume(@deviceReplayingVolume)
                      ).catch((err)=> env.logger.debug "Error in stopCasting " + err)
                    , duration)
                )
              )
            )
          catch err
            env.logger.debug "Error in launching device, " + err.message
            @announcement = false
            reject(err)
            return
        )
      )

    conversation: (_question, _volume) =>
      return new Promise((resolve,reject) =>

        @bodyConvers.command = _question
        @bodyConvers.broadcast = false
        @bodyConvers.converse = false

        env.logger.debug "@bodyConvers: " + JSON.stringify(@bodyConvers,null,2)

        needle('post',@ipAssistant, @bodyConvers, @opts)
        .then((resp)=>
          #env.logger.debug "Convers response: " + JSON.stringify(resp.body,null,2)
          if resp.body.audio?
            _url = @assistantRelayIp + ':' + @assistantRelayPort + resp.body.audio
            _url = 'http://' + _url unless _url.startsWith('http://')
            @playFile(_url, _volume)
            .then(()=>
              resolve()
            )
            .catch(()=>
              reject("can play assistant answer")
            )
          else
            reject("no assistant audio answer received")
        )
        .catch((err)=>
          env.logger.debug("error conversation handled: " + err)
          reject("converstation failed, " + err)
        )
      )

    playFile: (_url, _volume, _duration) =>
      return new Promise((resolve,reject) =>

        @bodyCast.source = _url
        if @devicePlaying
          @deviceReplaying = true
          @deviceReplayingUrl = @devicePlayingUrl
          @deviceReplayingInfo = @devicePlayingInfo
          @deviceReplayingVolume = @devicePlayingVolume
          @deviceReplayingMedia = @devicePlayingMedia
          @deviceReplayingPaused = @devicePaused
          #env.logger.debug "Replaying values set, vol: " + @deviceReplayingVolume + ", url: " + @deviceReplayingUrl + ", paused: " + @devicePaused
        else
          @deviceReplaying = false
          @deviceReplayingUrl = null # @devicePlayingUrl

        #_contentType = getContentType(_url)

        #needle('post',@ipCast, @bodyCast, @opts)
        _command = "catt -d #{@ip} cast " + _url
        exec(_command)
        .then((resp)=>
          env.logger.debug "Cast " + _url
          return @setVolume(_volume)
        )
        .then(()=>
          unless _duration?
            _duration = @duration
          env.logger.debug "Cast for " + _duration
          if _duration?
            @durationTimer = setTimeout(()=>
              env.logger.debug "Cast ends"
              @stop()
              if @deviceReplaying
                @replayFile(@deviceReplayingUrl, @deviceReplayingVolume, @deviceReplayingPaused)
                .then(()=>
                  resolve()
                )
                .catch((err)=>
                  env.logger.debug "Error replaying"
                  reject()
                )
            , _duration)
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error playing file handled: " + err)
          reject("playing file failed, " + err)
        )
      )

    replayFile: (_url, _volume, _paused) =>
      return new Promise((resolve,reject) =>

        env.logger.debug "replaying, url " + _url + ", vol " + _volume + ", pause? " + _paused
        @bodyCast.source = _url
        _command = "catt -d #{@ip} cast " + _url
        #exec(_command)
        needle('post',@ipCast, @bodyCast, @opts)
        .then((resp)=>
          env.logger.debug "Restart Cast " + _url
          return @setVolume(_volume)
        )
        .then(()=>          
          return exec("catt -d #{@ip} pause") if _paused
        )
        .finally(()=>
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error playing file handled: " + err)
          reject("playing file failed, " + err)
        )
      )

    stopCasting: () =>
      return new Promise((resolve,reject) =>
        client = new Device()
        client.on 'error', (err) =>
          env.logger.error "Error " + err
        app = DefaultMediaReceiver
        client.getAppAvailabilityAsync = util.promisify(client.getAppAvailability)
        client.getSessionsAsync = util.promisify(client.getSessions)
        client.joinAsync = util.promisify(client.join)
        client.launchAsync = util.promisify(client.launch)
        client.stopAsync = util.promisify(client.stop)
        client.connectAsync = (connectOptions) =>
          new Promise((resolve) => client.connect(connectOptions, resolve))
        opts =
          host: @ip
          port: @port

        try
          client.connectAsync(opts)
          .then(() =>
            return client.getAppAvailabilityAsync(app.APP_ID)
          )
          .then((availability) =>
            return client.getSessionsAsync()
          )
          .then((sessions) =>
            activeSession = sessions.find((session) => session.appId is app.APP_ID)
            if activeSession
              return client.joinAsync(activeSession, DefaultMediaReceiver)
            else
              return client.launchAsync(DefaultMediaReceiver)
          )
          .then((receiver) =>
            return client.stopAsync(receiver)
          )
          .finally(() =>
            client.close()
            resolve()
            return
          )
          .catch((err) =>
            env.logger.debug "Error in stop casting " + err
            reject()
          )
        catch err
          env.logger.error "Catched Error in stopCasting " + err
          reject()
      )

    restartPlaying: (_url, _vol, @_pause) =>
      return new Promise((resolve,reject) =>
        device = new Device()
        device.on 'error', (err) =>
          if err.message.indexOf("ETIMEDOUT")
            env.logger.debug "ReplayDevice offline"
          else
            env.logger.debug "Error in ReplayDevice " + err.message

        # subscribe to inner client
        device.client.on 'close', () =>
          env.logger.debug "ReplayDevice Client Client closing"

        opts =
          host: @ip
          port: @port

        _media =
          contentId : _url
          contentType: getContentType(_url)
          streamType: 'BUFFERED'
        if @deviceReplayingMedia?.metadata?.title?
          defaultMetadata =
            metadataType: 0
            title: @deviceReplayingMedia.metadata.title
            #posterUrl: "https://avatars0.githubusercontent.com/u/6502361?v=3&s=400"
            #images: [
            #  { url: "https://avatars0.githubusercontent.com/u/6502361?v=3&s=20" }
            #],
          _media["metadata"] = @deviceReplayingMedia?.metadata # defaultMetadata

        device.connect(opts, (err) =>
          if err?
            env.logger.debug "Connect error " + err.message
            reject("Connect error " + err.message)
          @deviceStatus = on
          device.launch(DefaultMediaReceiver, (err, app) =>
            if err?
              env.logger.error "Launch error " + err.message
              reject("Launch error " + err.message)
            #@_devicePlayer = app
            @_autoplay = not @_pause
            if @_pause
              @devicePlayingInfo = (if @deviceReplayingMedia?.metadata?.title? then @deviceReplayingMedia.metadata.title else "")
              @attributes["info"].label = String @devicePlayingInfo
              if @devicePlayingInfo.length > 30
                @devicePlayingInfo = ((@devicePlayingInfo.substr(0,30)) + " ...")
              @setAttr "status", "paused"
              @setAttr "info", @devicePlayingInfo

            @setVolume(_vol)
            .then(()=>
              app.load(_media, {autoplay: @_autoplay}, (err,status) =>
                if err?
                  env.logger.debug 'Error load replay ' + err
                  reject(err)
                  return
                env.logger.debug '(Re)playing ' + _url + ", autoplay: " + @_autoplay
                resolve()
              )
            ).catch((err)=>
              env.logger.error "Error setting volume " + err
            )
          )
        )
      )

    setAnnouncement: (_announcement) =>
      @announcementText = _announcement
      #env.logger.debug "Announcement is: " + @announcementText

    getAnnouncement: () =>
      return @announcementText

    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        unless vol?
          reject()
        _vol = vol
        if vol > 1 then _vol /= 100
        if vol < 0 then _vol = 0
        @mainVolume = vol
        @setAttr("volume", vol)
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: _vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        @statusDevice.setVolume(data, (err) =>
          if err?
            reject()
            return
          resolve()
        )
      )

    stop: () =>
      return new Promise((resolve,reject) =>
        @stopCasting()
        .then((result) =>
          env.logger.debug "Stopping device '" + @id
          resolve()
        ).catch((err)=>
          @deviceStatus = off
          @setAttr("status","offline")
          @setAttr("info","")
          @onlineChecker()
          reject(err)
        )
      )

    destroy: ->
      @stopCasting()
      .then(()=>
        clearTimeout(@onlineCheckerTimer)
        clearTimeout(@startupTimer)
        clearTimeout(@durationTimer)
      ).catch((err)=>
        clearTimeout(@onlineCheckerTimer)
        clearTimeout(@startupTimer)
        clearTimeout(@durationTimer)
        env.logger.debug "Error in Destroy stopcasting " + err
      )
      super()

  class GoogleDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return

      if @plugin.config.assistantRelay 
        @assistantRelay = true
      else
        @assistantRelay = false

      @deviceStatus = off
      @deviceReconnecting = false
      @textFilename = @id + "_text.mp3"

      #
      # Configure attributes
      #

      @attributes = {}
      @attributeValues = {}
      _attrs = ["status","info","volume"]
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

      @assistantRelayIp = @plugin.config.assistantRelayIp
      @assistantRelayPort = @plugin.config.assistantRelayPort ? 3000
      @assistantRelayUser = @plugin.config.assistantRelayUser


      @ip = @config.ip

      @serverIp = @plugin.serverIp
      @serverPort = @plugin.serverPort
      @soundsDir = @plugin.soundsDir
      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @textFilename = @id + "_text.mp3"

      @media =
        url: baseUrl + "/" + @textFilename
        base: baseUrl
        filename: @textFilename

      @ipCast = @assistantRelayIp + ':' + @assistantRelayPort + '/cast'
      @ipCastStop = @ipCast + '/stop'
      @ipAssistant = @assistantRelayIp + ':' + @assistantRelayPort + '/assistant'

      @opts =
        json: true
        headers: {'Content-Type': 'application/json;charset=UTF-8'}

      @bodyInit =
        device: @ip
        source: @media.base + "/" + @plugin.initFilename
        type: 'remote'
      @bodyAnnouncement = 
        command: "no text yet"
        broadcast: true
        user: @assistantRelayUser
      @bodyCast = 
        device: @ip
        source: @media.base + "/" + @plugin.initFilename
        type: 'remote'
      @bodyConvers =
        command: "tell a joke"
        converse: true
        user: @assistantRelayUser


      #
      # Check if Device is online
      #
      
      @port = (if @config.port? then @config.port else 8009) # default single device port
      @heatbeatTime = 600000 # 10 minutes heartbeat
      @onlineChecker = () =>
        env.logger.debug "Heartbeat check online status device '#{@id}"
        ping.promise.probe(@ip,{timeout: 2})
        .then((host)=>
          if host.alive
            if @deviceStatus is on
              # status checked and device is online no action, schedule next heartbeat
              @onlineCheckerTimer = setTimeout(@onlineChecker,@heatbeatTime)
              return
            startupTime = () =>
              env.logger.debug "Device '#{@id}' is online"
              @deviceStatus = on
              @setAttr("status","online")
              @setAttr("info","")
              @initSounds()
            @startupTimer = setTimeout(startupTime,20000)
          else
            #@deviceStatus = off
            @setAttr("status","offline")
            env.logger.debug "Device '#{@id}' offline"
          @onlineCheckerTimer = setTimeout(@onlineChecker,@heatbeatTime)
        )
        .catch((err)=>
          env.logger.debug "Error pinging #{@ip} " + err
        )

      @framework.variableManager.waitForInit()
      .then(()=>
        @onlineChecker()
      )
    
      super()

    initSounds: () =>

      #
      # The sounds states setup
      #
      @currentDeviceState = "idle"
      #@announcement = false
      @devicePlaying = false
      @devicePaused = false
      @deviceReplaying = false
      @devicePlayingUrl = ""
      @deviceReplayingUrl = ""
      @devicePlayingVolume = @mainVolume

      #
      # The chromecast status listener setup
      #
      @statusDevice = new Device()
      @statusDevice.on 'error', (err) =>
        @deviceReconnecting = true
        if err.message.indexOf("ECONNREFUSED")
          env.logger.debug "Network config probably changed or device is offline"
        else if err.message.indexOf("ETIMEDOUT")
          env.logger.debug "StatusDevice offline"
        else
          env.logger.debug "Error in status device " + err.message

      # subscribe to inner client
      @statusDevice.client.on 'close', () =>
        @deviceStatus = off
        @deviceReconnecting = true
        env.logger.debug "StatusDevice Client Client closing"

      opts =
        host: @ip
        port: @port
      env.logger.debug "Connecting to statusDevice with opts: " + JSON.stringify(opts,null,2)

      @statusDevice.connect(opts, (err) =>
        if err?
          env.logger.debug "Connect error " + err.message
          return
        @deviceStatus = on
        env.logger.info "Device '#{@name}' connected"

        @mainVolume = 20
        @initVolume = 40

        if @config.playInit or !(@config.playInit?)
          unless @deviceReconnecting
            @setAnnouncement("init sounds")
            @playFile(@media.base + "/" + @plugin.initFilename, @initVolume, 5000)
            .then(()=>
            ).catch((err)=>
              env.logger.debug "playAnnouncement error handled " + err
            )

        @statusDevice.on 'status', (_status) =>

          if _status?.applications?
            if Boolean _status.applications[0].isIdleScreen
              @devicePlaying = false
              @devicePaused = false
              @deviceReplaying = false
              @devicePlayingUrl = ""
              @deviceReplayingUrl = ""
              @deviceReplayingPaused = false
              @setAttr "status", "idle"
              @setAttr "info", ""
              @setAttr "volume", @mainVolume

          if _status.volume?.level?
            @devicePlayingVolume = Math.round(_status.volume.level * 100)
            @mainVolume = @devicePlayingVolume
            @setAttr "volume", @mainVolume            

          if @statusDevice?
            @statusDevice.getSessions((err,sessions) =>
              if err?
                env.logger.error "Error getSessions " + err.message
                return
              if sessions.length > 0
                firstSession = sessions[0]
                if firstSession.transportId?
                  @statusDevice.join(firstSession, DefaultMediaReceiver, (err, app) =>
                    if err?
                      env.logger.error "Join error " + err.message
                      return
                    app.on 'status' , (status) =>
                      title = status?.media?.metadata?.title
                      contentId = status?.media?.contentId
                      if status.media?
                        env.logger.debug "Media info : " + JSON.stringify(status.media,null,2)
                      if status.playerState is "PLAYING" or status.playerState is "BUFFERING" or status.playerState is "IDLE" or status.playerState is "PAUSED"
                        if contentId                          
                          if (status.media.contentId).startsWith(@announcementUrl)
                            @setAttr "status", "annoucement"
                            @setAttr "info", @getAnnouncement()
                            return
                          else                          
                            if (status.media.contentId).startsWith("http")
                              @devicePlayingUrl = status.media.contentId
                            else
                              @devicePlayingUrl = null
                            #@devicePlayingInfo = title ? "" #(if status?.media?.metadata?.title? then status.media.metadata.title)
                            if title? 
                              @devicePlayingInfo = title
                            unless @devicePlayingInfo?
                              @devicePlayingInfo = ""
                            @attributes["info"].label = String @devicePlayingInfo
                            if @devicePlayingInfo.length > 30
                              @devicePlayingInfo = ((@devicePlayingInfo.substr(0,30)) + " ...")
                            @devicePlayingMedia = status.media
                            @setAttr "info", @devicePlayingInfo
                            if status.media?.duration?
                              @duration = status.media.duration * 1000
                        @devicePlaying = if (status.playerState is "PLAYING" or status.playerState is "BUFFERING") then true else false
                        @devicePaused = if status.playerState is "PAUSED" then true else false
                        @setAttr "status", status.playerState.toLowerCase()
                        return
                      if status.playerState is "IDLE" and status.idleReason is "FINISHED"
                        @devicePlaying = false
                        @devicePaused = false
                        @setAttr "status", "idle"
                        @setAttr "info", ""
                        return
                      if status.playerState is "PAUSED"
                        #env.logger.debug "PlayerState is PAUSED"
                        @devicePlaying = true
                        @devicePaused = true
                        @setAttr "status", "paused"
                        @setAttr "info", ""
                        return
                  )
              else
                # sessions == 0
                @devicePlaying = false
                @devicePaused = false
                @setAttr "status", "idle"
                @setAttr "info", ""
            )
      )

    setAnnouncement: (_announcement) =>
      @announcementText = _announcement
      #env.logger.debug "Announcement is: " + @announcementText
    getAnnouncement: () =>
      return @announcementText

    setOpts: (ip, port) =>
      @ip = ip
      @port = port

    setAttr: (attr, _status) =>
      unless @attributeValues[attr] is _status
        @attributeValues[attr] = _status
        @emit attr, @attributeValues[attr]

        #env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playFile: (_url, _volume, _duration) =>
      return new Promise((resolve,reject) =>

        @bodyCast.source = _url
        @deviceReplayingVolume = @devicePlayingVolume
        if @devicePlaying
          @deviceReplaying = true
          @deviceReplayingUrl = @devicePlayingUrl
          @deviceReplayingInfo = @devicePlayingInfo
          @deviceReplayingMedia = @devicePlayingMedia
          @deviceReplayingPaused = @devicePaused
          #env.logger.debug "Replaying values set, vol: " + @deviceReplayingVolume + ", url: " + @deviceReplayingUrl + ", paused: " + @devicePaused
        else
          @deviceReplaying = false
          @deviceReplayingUrl = null # @devicePlayingUrl

        #_contentType = getContentType(_url)

        #needle('post',@ipCast, @bodyCast, @opts)
        _command = "catt -d #{@ip} cast " + _url
        exec(_command)
        .then((resp)=>
          env.logger.debug "Cast " + _url
          return @setVolume(_volume)
        )
        .then(()=>
          unless _duration?
            _duration = @duration
          env.logger.debug "Cast for " + _duration
          if _duration?
            @durationTimer = setTimeout(()=>
              env.logger.debug "Cast ends"
              @stop()
              if @deviceReplaying
                @replayFile(@deviceReplayingUrl, @deviceReplayingVolume, @deviceReplayingPaused)
                .then(()=>
                  resolve()
                )
                .catch((err)=>
                  env.logger.debug "Error replaying"
                  reject()
                )
              else
                @setVolume(@deviceReplayingVolume)
            , _duration)
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error playing file handled: " + err)
          reject("playing file failed, " + err)
        )
      )

    replayFile: (_url, _volume, _paused) =>
      return new Promise((resolve,reject) =>

        env.logger.debug "replaying, url " + _url + ", vol " + _volume + ", pause? " + _paused
        @bodyCast.source = _url
        _command = "catt -d #{@ip} cast " + _url
        #exec(_command)
        needle('post',@ipCast, @bodyCast, @opts)
        .then((resp)=>
          env.logger.debug "Restart Cast " + _url
          return @setVolume(_volume)
        )
        .then(()=>          
          return exec("catt -d #{@ip} pause") if _paused
        )
        .finally(()=>
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error playing file handled: " + err)
          reject("playing file failed, " + err)
        )
      )


    playAnnouncement: (_text, _volume) => 
      return new Promise((resolve,reject) =>

        @bodyAnnouncement.command = _text

        needle('post',@ipAssistant, @bodyAnnouncement, @opts)
        .then((resp)=>
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error announcement handled: " + err)
          reject("playing announcement failed, " + err)
        )
      )

    conversation: (_question, _volume) =>
      return new Promise((resolve,reject) =>

        @bodyConvers.command = _question
        @bodyConvers.broadcast = false
        @bodyConvers.converse = false

        needle('post',@ipAssistant, @bodyConvers, @opts)
        .then((resp)=>
          env.logger.debug "Convers response: " + JSON.stringify(resp.body,null,2)
          if resp.body.audio?
            _url = @assistantRelayIp + ':' + @assistantRelayPort + resp.body.audio
            _url = 'http://' + _url unless _url.startsWith('http://')
            @playFile(_url, _volume)
            .then(()=>
              resolve()
            )
            .catch(()=>
              reject("can play assistant answer")
            )
          else
            reject("no assistant audio answer received")
        )
        .catch((err)=>
          env.logger.debug("error conversation handled: " + err)
          reject("converstation failed, " + err)
        )
      )

    conversationOld: (_question, _volume) =>
      return new Promise((resolve,reject) =>

        @bodyConvers.command = _question

        #env.logger.debug "Conversation: " + JSON.stringify(@bodyConvers,null,2)
        needle('post',@ipAssistant, @bodyConvers, @opts)
        .then((resp)=>
          #env.logger.info "Converstation response: " + JSON.stringify(resp,null,2)
          #env.logger.debug "Response received: " + JSON.stringify(resp.body.audio,null,2)
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error conversation handled: " + err)
          reject("converstation failed, " + err)
        )
      )



    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        unless vol?
          reject()
        _vol = vol
        if vol < 1 then _vol *= 100
        if vol > 100 then _vol = 100
        if vol < 0 then _vol = 0
        _vol = Math.round(_vol)
        @setAttr "volume", vol
        _command = 'catt -d ' + @ip + ' volume ' + _vol
        exec(_command)
        .then((resp)=>
          resolve()
        )
        .catch((err)=>
          env.logger.debug "Error setVolume handled: " + err
          reject(err)
        )
      )

    stop: () =>
      return new Promise((resolve,reject) =>
        _body = 
          device: @ip
          force: true
        @setAttr("status","idle")
        @setAttr("info","")
        exec('catt -d ' + @ip + ' stop')
        #needle('post', @ipCastStop, _body, @opts)
        .then((resp)=>
          resolve()
        )
        .catch((err)=>
          env.logger.debug("error stop playing file handled: " + err)
          reject("stop playing file failed")
        )
      )

    destroy: ->
      @stop()
      .then(()=>
        try
          #if @statusDevice?
          #  @statusDevice.close()
          #  @statusDevice.removeAllListeners()
        catch err
          env.logger.debug "Destroy error handled " + err
        clearTimeout(@onlineCheckerTimer)
        clearTimeout(@startupTimer)
      ).catch((err)=>
        env.logger.debug "Error in Destroy stopcasting " + err
      )
      super()


  class SonosDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed then return
      @deviceStatus = off
      @deviceReconnecting = false
      @textFilename = @id + "_text.mp3"

      #
      # Configure attributes
      #
      @attributes = {}
      @attributeValues = {}
      _attrs = ["status","info","volume"]
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
              @setAttr("status","idle")
              @setAttr("info","")
              @initSounds()
            @startupTimer = setTimeout(startupTime,15000)
          else
            @deviceStatus = off
            @setAttr("status","offline")
            env.logger.debug "Device '#{@id}' offline"
            @onlineCheckerTimer = setTimeout(@onlineChecker,600000)
        )
        .catch((err)=>
          env.logger.debug "Error pinging #{@ip} " + err
        )

      @framework.variableManager.waitForInit()
      .then(()=>
        @onlineChecker()
      )

      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @gtts = @plugin.gtts

      @mainVolume = 20
      @initVolume = 40
      @devicePlayingVolume = 20

      @serverIp = @plugin.serverIp
      @serverPort = @plugin.serverPort
      @soundsDir = @plugin.soundsDir
      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @textFilename = @id + "_text.mp3"

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
        unless @deviceReconnecting
          @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume, "init sounds", null)

      @sonosDevice.on 'PlayState', (state) =>
        env.logger.debug 'The PlayState changed to ' + state
        if state is "playing" and @announcement is false
          @setAttr("status",state)
          @sonosDevice.currentTrack()
          .then((track) =>
            env.logger.debug 'Current track ' + JSON.stringify(track,null,2)
            @setAttr("info",track.title)
          )
        if state is "playing" and @announcement
          @setAttr("status","announcement")
          @setAttr("info",@announcementText)
        if state is "stopped"
          @setAttr("status","idle")
          @setAttr("info","")
        if state is "stopped" and @announcement
          @announcement = false
          @setAttr("status","idle")
          @setAttr("info","")

      @sonosDevice.on 'Volume', (volume) =>
        @mainVolume = volume
        @setAttr("volume", @mainVolume)
        @devicePlayingVolume = volume
        env.logger.debug "New mainvolume '" + @devicePlayingVolume + "'' in device '" + @id + "'"

      @sonosDevice.on 'Mute', (isMuted) =>
        env.logger.debug 'Mute changed to ' + isMuted

    setAttr: (attr, _status) =>
      unless @attributeValues[attr] is _status
        @attributeValues[attr] = _status
        @emit attr, @attributeValues[attr]
        env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol, _text, _duration) =>
      return new Promise((resolve,reject) =>
        @announcement = true
        if _text?
          @announcementText = _text
        unless @sonosDevice?
          info.logger.debug "Device #{@id} handled"
          reject()
          return
        #  @onlineChecker()
        #  reject("Device not online")
        media =
          uri : _url
          onlyWhenPlaying: false
          volume: _vol
        @sonosDevice.playNotification(media)
        .then((result) =>
          env.logger.debug "Playing announcement on device '" + @id + "' with volume " + _vol
          resolve()
        ).catch((err)=>
          @deviceStatus = off
          @deviceReconnecting = true
          @setAttr("status","offline")
          @setAttr("info","")
          @onlineChecker()
          reject(err)
        )
      )

    playFile: (_file) =>
      return new Promise((resolve,reject) =>
        reject("Not implemented")
      )

    setAnnouncement: (_announcement) =>
      @announcementText = _announcement

    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        if vol > 100 then vol 100
        if vol < 0 then vol = 0
        @mainVolume = vol
        @setAttr("volume", @mainVolume)
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        @sonosDevice.setVolume(vol) # @sonosDevice.setVolume(vol)
        .then((_vol)=>
          resolve()
        ).catch((err)=>
          env.logger.debug "Error in setVolume " + err
          reject()
        )
      )

    stop: () =>
      return new Promise((resolve,reject) =>
        @sonosDevice.stop()
        .then((result) =>
          env.logger.debug "Stopping device '" + @id
          resolve()
        ).catch((err)=>
          @deviceStatus = off
          @setAttr("status","offline")
          @setAttr("info","")
          @onlineChecker()
          reject(err)
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


  class GroupDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      checkMultipleDevices = []
      for _device in @config.devices
        do(_device) =>
          if _.find(checkMultipleDevices, (d) => d.name is _device.name)?
            throw new Error "#{_device.name} is already used"
          else
            checkMultipleDevices.push _device

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
      @setAttr("status","idle")

      @serverIp = @plugin.serverIp
      @serverPort = @plugin.serverPort
      @soundsDir = @plugin.soundsDir

      @textFilename = @id + "_text.mp3"

      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @media =
        url: baseUrl + "/" + @textFilename
        base: baseUrl
        filename: @textFilename

      @gtts = @plugin.gtts
      super()

    playAnnouncement: (_url, _vol, _text, _duration) =>
      return new Promise((resolve,reject) =>
        #env.logger.info "@framework.deviceManager.getDeviceById(@id) " + JSON.stringify((@framework.deviceManager.getDeviceById(@id)).config.devices,null,2)
        for _dev in (@framework.deviceManager.getDeviceById(@id)).config.devices
          device = @framework.deviceManager.getDeviceById(_dev.name)
          if device.deviceStatus is on
            device.setAnnouncement(_text)
            device.playAnnouncement(_url, Number _vol, _text, _duration)
            .then(()=>
              env.logger.debug "Groupsdevice initiates announcement on device '" + device.id + "'"
              @setAttr("status","annoucement")
              @setAttr("info",_url)
              @announcementTimer = setTimeout(=>
                @setAttr("status","")
                @setAttr("info","")
              ,5000)
            ).catch((err)=>
              env.logger.debug "Error in Group playAnnouncement: " + err
              reject()
            )
          else
            env.logger.debug "Device #{device.id} is offline"
        resolve()
      )

    stop: () =>
      return new Promise((resolve,reject) =>
        device.stop()
        .then((result) =>
          env.logger.debug "Stopping group device '" + @id
          resolve()
        ).catch((err)=>
          @deviceStatus = off
          @setAttr("status","offline")
          @setAttr("info","")
          @onlineChecker()
          reject(err)
        )
      )


    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    setAnnouncement: (_announcement) =>
      @announcementText = _announcement

    destroy: ->
      clearTimeout(@announcementTimer)
      super()

  class SoundsActionProvider extends env.actions.ActionProvider

    constructor: (@framework, @soundsClasses, @dir) ->
      @root = @dir
      @mainVolume = 30

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
      volumeVar = null
      duration = null
      durationVar = null
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
      setAskString = (m, tokens) =>
        soundType = "ask"
        text = tokens
        return

      setFilename = (m, tokens) =>
        soundType = "file"
        text = tokens
        if (text.join('')).indexOf(" ") >= 0
          context?.addError("no spaces allowed in filestring")
          return
        return

      setFilenameString = (m, filename) =>
        fullfilename = path.join(@root, filename)
        try
          stats = fs.statSync(fullfilename)
          if fullfilename.indexOf(" ")>=0
            context?.addError("'" + fullfilename + "' no spaces allowed in filename")
            return
          else if stats.isFile()
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
        volume = vol
        return

      setMainVolumeVar = (m, tokens) =>
        volumeVar = tokens
        return

      setDuration = (m, {time, unit, timeMs}) =>
        #if time < 1
        #  context?.addError("Duration must be mimimal 1 second")
        #if time >500
        #  context?.addError("Duration can be maximal 500 seconds")
        duration = timeMs
        match = m.getFullMatch()

      setDurationVar = (m, tokens) =>
        durationVar = tokens
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
            return m.match('text ')
              .matchStringWithVars(setLogString)
          ),
          ((m) =>
            return m.match('file ')
              .matchStringWithVars(setFilename)
          ),
          ((m) =>
            return m.match('ask ')
              .matchStringWithVars(setAskString)
          ),
          ((m) =>
            return m.match('main', (m)=>
              soundType = "vol"
            )
          ),
          ((m) =>
            return m.match('stop', (m)=>
              soundType = "stop"
            )
          )
        ])
        .or([
          ((m) =>
            return m.match(' vol ')
              .or([
                ((m) =>
                  return m.matchVariable(setMainVolumeVar)
                ),
                ((m) =>
                  return m.matchNumber(setMainVolume)
                )
                ])
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
        .match(' for ', optional: yes, (m)=>
          m.matchTimeDurationExpression( (m, tokens) =>
            env.logger.debug "Duration tokens " + JSON.stringify(tokens,null,2)
            durationVar = tokens
            match = m.getFullMatch()
          )
        )

      #match = m.getFullMatch()

      unless volume?
        volume = @mainVolume

      if m.hadMatch()
        env.logger.debug "Rule matched: '", match, "' and passed to Action handler"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new SoundsActionHandler(@framework, @, text, soundType, soundsDevice, volume, volumeVar, duration, durationVar)
        }
      else
        return null


  class SoundsActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @actionProvider, @textIn, @soundType, @soundsDevice, @volume, @volumeVar, @duration, @durationVar) ->

    executeAction: (simulate) =>
      if simulate
        return __("would save file \"%s\"", @textIn)
      else
        if @soundsDevice.deviceStatus is off
          if @soundType is "text" or @soundType is "file"
            return __("Rule not executed device offline")
          else
            return __("Rule not executed device offline")
        try
          #env.logger.info "Execute: " +@soundType + ", @textIn"
          switch @soundType
            when "text"
              @framework.variableManager.evaluateStringExpression(@textIn).then( (strToLog) =>
                @text = strToLog
                if @volumeVar?
                  newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                  if newVolume?
                    if newVolume > 100 then newVolume = 100
                    if newVolume < 0 then newVolume = 0
                  else
                    return __("\"%s\" volume variable no value", @text)
                else
                  newVolume = @volume

                if @soundsDevice.config.class is "GoogleDevice"
                  # no text to speech conversion needed
                  #@soundsDevice.setAnnouncement(@text)
                  @soundsDevice.playAnnouncement(@text, Number newVolume)
                  .then(()=>
                    env.logger.debug 'Playing ' + @text
                    return __("\"%s\" was played ", @text)
                  ).catch((err)=>
                    env.logger.debug "Error in playAnnouncement: " + err
                    return __("\"%s\" was not played", @text)
                  )
                else
                  env.logger.debug "Creating sound file... with text: " + @text
                  @soundsDevice.gtts.save((@soundsDevice.soundsDir + "/" + @soundsDevice.textFilename), @text, () =>
                    ###
                    if err?
                      env.logger.debug "Error: " + err
                      return __("\"%s\" was not generated", @text)
                    ###
                    env.logger.debug "Sound generated, now casting " + @soundsDevice.media.url
                    @soundsDevice.setAnnouncement(@text)
                    @soundsDevice.playAnnouncement(@soundsDevice.media.url, Number newVolume, @text, @duration)
                    .then(()=>
                      env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + newVolume + ", and text " + @text
                      return __("\"%s\" was played ", @text)
                    ).catch((err)=>
                      env.logger.debug "Error in playAnnouncement: " + err
                      return __("\"%s\" was not played", @text)
                    )
                )
              )
            when "ask"
              @framework.variableManager.evaluateStringExpression(@textIn).then( (strToLog) =>
                @text = strToLog
                if @volumeVar?
                  newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                  if newVolume?
                    if newVolume > 100 then newVolume = 100
                    if newVolume < 0 then newVolume = 0
                  else
                    return __("\"%s\" volume variable no value", @text)
                else
                  newVolume = @volume
                #if @soundsDevice.config.class is "GoogleDevice"
                if @soundsDevice.assistantRelay? and @soundsDevice.assistantRelay
                  # no text to speech conversion needed
                  #@soundsDevice.setAnnouncement(@text)
                  @soundsDevice.conversation(@text, Number newVolume)
                  .then(()=>
                    env.logger.debug 'Asking ' + @text
                    return __("\"%s\" was asked ", @text)
                  ).catch((err)=>
                    env.logger.debug "Error in conversation: " + err
                    return __("\"%s\" was not asked", @text)
                  )
                else
                  env.logger.debug "Creating sound file... with text: " + @text
                  @soundsDevice.gtts.save((@soundsDevice.soundsDir + "/" + @soundsDevice.textFilename), @text, () =>
                    #if err?
                    #  env.logger.debug "Error: " + err
                    #  return __("\"%s\" was not generated", @text)
                    env.logger.debug "Sound generated, now casting " + @soundsDevice.media.url
                    @soundsDevice.setAnnouncement(@text)
                    @soundsDevice.playAnnouncement(@soundsDevice.media.url, Number newVolume, @text, @duration)
                    .then(()=>
                      env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + newVolume + ", and text " + @text
                      return __("\"%s\" was played ", @text)
                    ).catch((err)=>
                      env.logger.debug "Error in playAnnouncement: " + err
                      return __("\"%s\" was not played", @text)
                    )
                )
              )
            when "file"
              @framework.variableManager.evaluateStringExpression(@textIn).then( (strToLog) =>
                @text = strToLog
                if @text.indexOf(" ")>=0
                  env.logger.debug "No spaces allowed in filename, rule not executed"
                  return __("No spaces allowed in filename, rule not executed")
                if @text.startsWith("http")
                  fullFilename = @text
                else
                  fullFilename = (@soundsDevice.media.base + "/" + @text)
                env.logger.debug "Playing sound file... " + fullFilename

                if @volumeVar?
                  newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                  if newVolume?
                    if newVolume > 100 then newVolume = 100
                    if newVolume < 0 then newVolume = 0
                  else
                    return __("\"%s\" volume variable no value", @text)
                else
                  newVolume = @volume

                if @durationVar?
                  _newDuration = @framework.variableManager.getVariableValue((String @durationVar.tokens[0]).replace("$",""))
                  if _newDuration?
                    newDuration = milliseconds.parse("#{_newDuration} #{@durationVar.unit}")
                  else
                    _newDuration = Number @durationVar.tokens[0]
                    unless Number.isNaN(_newDuration)
                      newDuration = milliseconds.parse("#{_newDuration} #{@durationVar.unit}")
                    else
                      return __("\"%s\" duration variable no value", @text)
                else
                  newDuration = null
                @soundsDevice.setAnnouncement(@text)

                if @soundsDevice.config.class is "GoogleDevice"
                  @soundsDevice.playFile(fullFilename, (Number newVolume), newDuration)
                  .then(()=>
                    env.logger.debug 'Playing ' + fullFilename + " with volume " + newVolume
                    return __("\"%s\" was played ", @text)
                  ).catch((err)=>
                    env.logger.debug "Error in playAnnouncement: " + err
                    return __("\"%s\" was not played", @text)
                  )
                else
                  @soundsDevice.playAnnouncement(fullFilename, (Number newVolume), @text, newDuration)
                  .then(()=>
                    env.logger.debug 'Playing ' + fullFilename + " with volume " + newVolume + ", _duration " + newDuration
                    return __("\"%s\" was played ", @text)
                  ).catch((err)=>
                    env.logger.debug "Error in playAnnouncement: " + err
                    return __("\"%s\" was not played", @text)
                  )
              )

            when "vol"
              @text = "volume set"
              if @volumeVar?
                newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                if newVolume?
                  if newVolume > 100 then newVolume = 100
                  if newVolume < 0 then newVolume = 0
                else
                  return __("volume variable does not excist")
              else
                newVolume = @volume
              @soundsDevice.setVolume(Number newVolume)
              .then(()=>
                return __("\"%s\" was played with volume set", newVolume)
              ).catch((err)=>
                env.logger.debug "Error setting volume " + err
                return __("\"%s\" was played but volume was not set", newVolume)
              )

            when "stop"
              @text = "playing stopped"
              @soundsDevice.stop()
              .then(()=>
                return __("playing was stopped")
              ).catch((err)=>
                env.logger.debug "Error stopping " + err
                return __("playing was not stopped")
              )

            else
              env.logger.debug 'error: unknown playtype'
              return __("\"%s\" unknown playtype", @soundType)

          return __("\"%s\" executed", @text)
        catch err
          @soundsDevice.deviceStatus = off
          env.logger.debug "Device offline, start onlineChecker " + err
          @soundsDevice.onlineChecker()
          return __("\"%s\" Rule not executed device offline") + err

  soundsPlugin = new SoundsPlugin
  return soundsPlugin
