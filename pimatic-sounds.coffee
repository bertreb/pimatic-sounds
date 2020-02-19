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
  util = require('util')
  getContentType = require('./content-types.js')
  bonjour = require('bonjour')()

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
      @mainVolume = 0.40
      @initVolume = 0.40
      baseUrl = "http://" + @serverIp + ":" + @serverPort

      @serverPort = if @config.port? then @config.port else 8088
      @server = http.createServer((req, res) =>
        fs.readFile @soundsDir + "/" + req.url, (err, data) ->
          if err
            res.writeHead 404
            res.end JSON.stringify(err)
            return
          contentType = getContentType(req.url)
          res.writeHead 200, {'Content-Type': contentType } #'audio/mpeg'}
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
        #if bonjour?
        #  bonjour.destroy()
        env.logger.debug "Stopping plugin, closing server"

      pluginConfigDef = require './pimatic-sounds-config-schema'
      @configProperties = pluginConfigDef.properties

      deviceConfigDef = require("./device-config-schema")

      oldClassName = "SoundsDevice"
      newClassName = "ChromecastDevice"
      @soundsClasses = ["ChromecastDevice","SonosDevice"]
      @soundsAllClasses = ["ChromecastDevice","SonosDevice","GroupDevice"]
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
                #@initSounds = false
                #env.logger.info "device.config " + JSON.stringify(device.config,null,2)
                #env.logger.info "service.name " + service.name
                #env.logger.info "config.devices " + JSON.stringify(_.find(@framework.config.devices,(d)=> d.id == service.name),null,2)
                if address.indexOf(device.config.ip)<0 or service.port != device.config.port
                  config =
                    id: device.config.id
                    name: device.config.name
                    ip: address
                    class: device.config.class
                    port: service.port
                    playInit: device.config.playInit
                  
                  #@framework.deviceManager.updateDeviceByConfig(config)
                  device.config.ip = address
                  device.config.port = service.port
                  device.setOpts(address, service.port)

              if not @allreadyInConfig
                if service.txt.md?
                  if friendlyName?
                    newName = service.txt.md + " - " + friendlyName
                    newId = checkId #(service.txt.md).replace(/\s+/g, '_') + "_" + friendlyName
                  else
                    newName = service.txt.md + "_" + address.split('.').join("") + " - " + service.port
                    newId = (service.txt.md).replace(/\s+/g, '_') + "_" + address.split('.').join("") + "-" + service.port
                else
                  newName = "cast " + address.split('.').join("") + " - " + service.port
                  newId = "cast_" + address.split('.').join("") + "-" + service.port
                #env.logger.debug "New device discovered " + newName
                config =
                  id: service.txt.id # newId
                  name: newName
                  class: "ChromecastDevice"
                  ip: address
                  port: service.port
                @framework.deviceManager.discoveredDevice( "pimatic-sounds", config.name, config)
              else
                env.logger.info "Device already in config"
        )
        @browser.start()
      )
      

      ipInConfig = (deviceIP, devicePort, cn) =>
        for device in @framework.deviceManager.devicesConfig
          if device.ip?
            if ((device.ip).indexOf(String deviceIP) >= 0) and cn.indexOf(device.class)>=0
              if device.port?
                if Number device.port == Number devicePort
                  env.logger.info "device " + deviceIP + " (" + cn + ") already in config"
                  return true
              else
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
      @port = (if @config.port? then @config.port else 8009) # default single device port
      @onlineChecker = () =>
        if @onlineCheckerTimer?
          env.logger.debug "Online checker already running"
          return
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
            @onlineCheckerTimer = setTimeout(@onlineChecker,15000)
        )
      @onlineChecker()

      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      @mainVolume = 0.40
      @initVolume = 0.40

      @serverPort = @plugin.serverPort
      @serverIp = @plugin.serverIp
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

      if @config.playInit or !(@config.playInit?)
        @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume)
        .then(()=>
        ).catch((err)=>
          env.logger.debug "playAnnouncement error handled"
        )


      #
      # The chromecast status listener setup
      #
      @statusDevice = new Device()
      @statusDevice.on 'error', (err) =>
        @deviceStatus = off
        if err.message.indexOf("ECONNREFUSED")
          env.logger.debug "Network config probably changed, please start discovery"
          #@framework.deviceManager.discoverDevices(15000)
        env.logger.debug "Error in statusDevice " + err.message
        try
          @destroy()
        catch err
          env.logger.debug "GaDevice error on destroy solved"
        @onlineCheckerTimer = setTimeout(@onlineChecker,15000)

      # subscribe to inner client
      @statusDevice.client.on 'close', () =>
        @deviceStatus = off
        env.logger.debug "Client Client closing" 
        @onlineCheckerTimer = setTimeout(@onlineChecker,10000)

      opts =
        host: @ip
        port: @port
      env.logger.debug "Connecting to statusDevice with opts: " + JSON.stringify(opts,null,2)

      @statusDevice.connect(opts, (err) =>
        if err?
          env.logger.debug "Connect error " + err.message
          return
        @deviceStatus = on
        env.logger.info "Device connected"

        if @config.playInit or !(@config.playInit?)
          @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume)
          .then(()=>
          ).catch((err)=>
            env.logger.debug "playAnnouncement error handled"
          )

        @statusDevice.on 'status', (status) =>
          #
          # get volume
          #
          if status.volume?.level?
            @devicePlayingVolume = status.volume.level
            @mainVolume = @devicePlayingVolume
            env.logger.debug "New mainvolume '" + @devicePlayingVolume + "'' in device '" + @id + "'"

          @statusDevice.getSessions((err,sessions) =>
            if err?
              env.logger.error "Error getSessions " + err.message
              return
            if sessions.length > 0
              firstSession = sessions[0]
              if firstSession.transportId?
                #
                # Join the chromecast info device
                #
                @statusDevice.join(firstSession, DefaultMediaReceiver, (err, app) =>
                  if err?
                    env.logger.error "Join error " + err.message
                    return
                  #@_deviceInfo = app
                  app.on 'status' , (status) =>
                    title = status?.media?.metadata?.title
                    contentId = status?.media?.contentId
                    if status.playerState is "IDLE" and @devicePlaying
                      @devicePlaying = false
                      @setAttr "status", "idle"
                      @setAttr "info", ""
                    else if status.playerState is "PLAYING" and not @devicePlaying
                      @devicePlaying = true
                      if contentId
                        if (status.media.contentId).startsWith("http")
                          @devicePlayingUrl = status.media.contentId
                      @devicePlayingInfo = (if status?.media?.metadata?.artist then status.media.metadata.artist else "")
                      @devicePlayingMedia = status.media
                      if @annoucement
                        @setAttr "status", "announcement"
                        @setAttr "info", @devicePlayingUrl
                      else
                        @setAttr "status", "playing"
                        @setAttr "info", @devicePlayingInfo
                )
          )
      )

    setOpts: (ip, port) =>
      @ip = ip
      @port = port

    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol, _duration) =>
      return new Promise((resolve,reject) =>
        #unless @gaDevice?
        #  reject("Device not online")
        #  return

        device = new Device()

        device.on 'error', (err) =>
          @deviceStatus = off
          if err.message.indexOf("ECONNREFUSED")
            env.logger.debug "Network config probably changed, please start discovery"
            #@framework.deviceManager.discoverDevices(15000)
          env.logger.debug "Error in gaDevice " + err.message
          #try
          #  @destroy()
          #catch err
          #  env.logger.debug "GaDevice error on destroy solved"
          @onlineCheckerTimer = setTimeout(@onlineChecker,15000)

        # subscribe to inner client
        device.client.on 'close', () =>
          @deviceStatus = off
          env.logger.debug "Client Client closing" 
          @onlineCheckerTimer = setTimeout(@onlineChecker,10000)

        opts =
          host: @ip
          port: @port

        env.logger.debug "Connecting to gaDevice with opts: " + JSON.stringify(opts,null,2)
        device.connect(opts, (err) =>
          if err?
            env.logger.debug "Connect error " + err.message
            return
          @deviceStatus = on
          env.logger.info "PlayAnnouncement device connected"
          if @devicePlaying
            @deviceReplaying = true
            @annoucement = true
            @deviceReplayingUrl = @devicePlayingUrl
            @deviceReplayingInfo = @devicePlayingInfo
            @deviceReplayingVolume = @devicePlayingVolume
            @deviceReplayingMedia = @devicePlayingMedia
            env.logger.debug "Replaying values set"
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
            #metadata: defaultMetadata

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
                #env.logger.info "STATUS: " + JSON.stringify(status,null,2)
                if status.playerState is "IDLE" and status.idleReason is "FINISHED"
                  @stopCasting()
                  .then(() =>
                    env.logger.debug "Casting stopped"
                    if @deviceReplaying
                      @restartPlaying(device, @deviceReplayingUrl, @deviceReplayingVolume)
                      .then(()=>
                        env.logger.debug "Media restarted: " + @deviceReplayingUrl
                        device.close()
                        .then(()=>
                          resolve()
                        ).catch((err) =>
                          env.logger.error "Error in closing announcement device " + err
                        )
                      ).catch((err)=>
                        env.logger.error "Error startReplaying " + err
                        reject()
                        return
                      )
                  ).catch((err) =>
                    env.logger.error "Error in stopping casting: " + err
                    reject()
                    return
                  )
              @_devicePlayer = app
              @setVolume(device, _vol)
              .then(()=>
                app.load(media, {autoplay:true}, (err,status) =>
                  if err?
                    env.logger.error 'Error in playing announcement: ' + err
                    reject(err)
                    return
                  @annoucement = true
                  env.logger.debug "Playing annoucement on device '" + @id + "' with volume " + _vol
                  if _duration? or _duration > 0
                    # set durationTimer
                    setTimeout(=>
                      @stopCasting()
                      .then(()=>
                        env.logger.debug "Annoucement image auto stopped"
                      ).catch((err)=> env.logger.debug "Error in Annouvement imgage auto stop")
                    ,_duration * 1000)
                )
              )
            )
          catch err
            env.logger.debug "Error lauching client not ready, " + err.message
            reject(err)
            return
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
          env.logger.error "Error in stopCasting " + err
          reject()
      )

    restartPlaying: (device, _url, _vol) =>
      return new Promise((resolve,reject) =>
        try
          #media =
          #  contentId : _url
          #  contentType: getContentType(_url)
          #  streamType: 'BUFFERED'
          device.launch(DefaultMediaReceiver, (err, app) =>
            if err?
              env.logger.error "Launch error " + err.message
              return
            @_devicePlayer = app
            @setVolume(_vol)
            .then(()=>
              app.load(@deviceReplayingMedia, {autoplay:true}, (err,status) =>
                if err?
                  env.logger.error 'Error load replay ' + err
                  reject(err)
                  return
                @annoucement = false
                env.logger.debug '(Re)playing ' + _url
                resolve()
              )
            ).catch((err)=>
              env.logger.error "Error setting volume " + err
            )
          )
        catch err
          env.logger.error "Error restarting playing " + err
      )

    setVolume: (device, vol) =>
      return new Promise((resolve,reject) =>
        unless vol?
          reject()
        if vol > 1 then vol /= 100
        if vol < 0 then vol = 0
        @mainVolume = vol
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        device.setVolume(data, (err) =>
          if err?
            reject()
          resolve()
        )
      )

    destroy: ->
      @stopCasting()
      .then(()=>
        try
          if @statusDevice?
            @statusDevice.close()
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
              @setAttr("status","idle")
              @setAttr("info","")
              @initSounds()
            @startupTimer = setTimeout(startupTime,15000)
          else
            @deviceStatus = off
            @setAttr("status","offline")
            env.logger.debug "Device '#{@id}' offline"
            @onlineCheckerTimer = setTimeout(@onlineChecker,15000)
        )
      if @onlineCheckerTimer?
        clearTimeout(@onlineChecker)
        @onlineChecker()



      super()

    initSounds: () =>

      #
      # Configure tts
      #
      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      @mainVolume = 20
      @initVolume = 40
      
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
        @playAnnouncement(@media.base + "/" + @plugin.initFilename, @initVolume)

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
          @setAttr("info","")          
        if state is "stopped"
          @setAttr("status","idle")
          @setAttr("info","")
        if state is "stopped" and @announcement
          @announcement = false
          @setAttr("status","idle")
          @setAttr("info","")

      @sonosDevice.on 'Volume', (volume) =>
        env.logger.debug "New mainvolume '" + @devicePlayingVolume + "'' in device '" + @id + "'"
        @mainVolume = volume

      @sonosDevice.on 'Mute', (isMuted) =>
        env.logger.debug 'Mute changed to ' + isMuted

    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    playAnnouncement: (_url, _vol, _duration) =>
      return new Promise((resolve,reject) =>
        @announcement = true
        unless @sonosDevice?
          @onlineChecker()
          reject("Device not online")
        media =
          uri : _url
          onlyWhenPlaying: false
          volume: _vol
        @sonosDevice.playNotification(media)
        .then((result) =>
          env.logger.debug "Playing annoucement on device '" + @id + "' with volume " + _vol
          resolve()
        ).catch((err)=>
          @deviceStatus = off
          @setAttr("status","offline")
          @setAttr("info","")
          @onlineChecker()
          reject(err)
        )
      )

    setVolume: (vol) =>
      return new Promise((resolve,reject) =>
        if vol > 100 then vol 100
        if vol < 0 then vol = 0
        @mainVolume = vol
        @devicePlayingVolume = vol
        env.logger.debug "Setting volume to  " + vol
        data = {level: vol}
        env.logger.debug "Setvolume data: " + JSON.stringify(data,null,2)
        @sonosDevice.setVolume(data, (err) =>
          if err?
            reject(err)
            return
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

      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      super()

    playAnnouncement: (_url, _vol, _duration) =>
      return new Promise((resolve,reject) =>
        #env.logger.info "@framework.deviceManager.getDeviceById(@id) " + JSON.stringify((@framework.deviceManager.getDeviceById(@id)).config.devices,null,2)
        for _dev in (@framework.deviceManager.getDeviceById(@id)).config.devices
          device = @framework.deviceManager.getDeviceById(_dev.name)
          if device.deviceStatus is on 
            device.playAnnouncement(_url, Number _vol, _duration)
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

    setAttr: (attr, _status) =>
      @attributeValues[attr] = _status
      @emit attr, @attributeValues[attr]
      env.logger.debug "Set attribute '#{attr}' to '#{_status}'"

    destroy: ->
      clearTimeout(@announcementTimer)
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
      volumeVar = null
      duration = 0
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

      setDuration = (m, dur) =>
        if dur < 1
          context?.addError("Duration must be mimimal 1 second")
        if dur >120
          context?.addError("Duration can be maximal 120 seconds")
        duration = duration
        return

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
            return m.match('text ', optional: yes)
              .matchStringWithVars(setLogString)
          ),
          ((m) =>
            return m.match('file ', optional: yes)
              .matchStringWithVars(setFilename)
          ),
          ((m) =>
            return m.match('vol ', optional: yes)
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
                soundType = "vol"
                soundsDevice = d
                match = m.getFullMatch()
              )
          )
        ])
        .or([
          ((m) =>
            return m.match(' vol ', optional: yes)
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

      unless volume?
        volume = @mainVolume

      if match? # m.hadMatch()
        env.logger.debug "Rule matched: '", match, "' and passed to Action handler"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new SoundsActionHandler(@framework, @, text, soundType, soundsDevice, volume, volumeVar, duration)
        }
      else
        return null


  class SoundsActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @actionProvider, @textIn, @soundType, @soundsDevice, @volume, @volumeVar, @duration) ->


    executeAction: (simulate) =>
      if simulate
        return __("would save file \"%s\"", @textIn)
      else
        if @soundsDevice.deviceStatus is off
          @soundsDevice.onlineChecker()
          if @soundType is "text" or @soundType is "file"
            return __("Rule not executed device offline")
          else
            return __("\"%s\" Rule not executed device offline", @textIn)
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
                  if @volumeVar?
                    newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                    if newVolume?
                      if newVolume > 100 then newVolume = 100
                      if newVolume < 0 then newVolume = 0
                    else
                      return __("\"%s\" volume variable no value", @text)
                  else
                    newVolume = @volume
                  @soundsDevice.playAnnouncement(@soundsDevice.media.url, Number newVolume)
                  .then(()=>
                    env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + newVolume
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
                  return __("\"%s\" No spaces allowed in filename, rule not executed")
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
                @soundsDevice.playAnnouncement(fullFilename, Number newVolume, @duration)
                .then(()=>
                  env.logger.debug 'Playing ' + fullFilename + " with volume " + newVolume
                  return __("\"%s\" was played ", @textIn)
                ).catch((err)=>
                  env.logger.debug "Error in playAnnouncement: " + err
                  return __("\"%s\" was not played", @textIn)
                )
              )
            when "vol"
              if @volumeVar?
                newVolume = @framework.variableManager.getVariableValue(@volumeVar.replace("$",""))
                if newVolume?
                  if newVolume > 100 then newVolume = 100
                  if newVolume < 0 then newVolume = 0
                else
                  return __("\"%s\" volume variable no value", @text)
              else
                @newVolume = @volume
              @soundsDevice.setVolume((Number newVolume), (err) =>
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
