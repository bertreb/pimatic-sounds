module.exports = (env) ->
  Promise = env.require 'bluebird'
  assert = env.require 'cassert'
  http = require('http')
  fs = require('fs')
  path = require('path')
  _ = require('lodash')
  M = env.matcher
  Os = require('os')

  class SoundsPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>

      @dir = path.resolve @framework.maindir, '../..', 'sounds'
      if !fs.existsSync(@dir)
        env.logger.debug "Dir " + @dir + " doesn't exist, is created"
        fs.mkdirSync(@dir)

      pluginConfigDef = require './pimatic-sounds-config-schema'
      @configProperties = pluginConfigDef.properties

      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass('SoundsDevice', {
        configDef: deviceConfigDef.SoundsDevice,
        createCallback: (config, lastState) => new SoundsDevice(config, lastState, @framework, @)
      })
      @soundsClasses = ["SoundsDevice"]
      @framework.ruleManager.addActionProvider(new SoundsActionProvider(@framework, @soundsClasses, @dir))

  class SoundsDevice extends env.devices.Device

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      @language = @plugin.config.language ? "en"
      @gtts = require('node-gtts')(@language)

      for i, addresses of Os.networkInterfaces()
        for add in addresses
          if add.address.startsWith('192.168.')
            @serverIp = add.address
            env.logger.debug "Found IP adddress: " + @serverIp
      unless @serverIp?
        throw new Error "No IP address found!"
      #@serverIp = @plugin.config.ip
      @serverPort = @plugin.config.port ? 8088
      baseUrl = "http://" + @serverIp + ":" + @serverPort
      @soundsDir = @plugin.dir
      env.logger.debug "@Dir " + @dir
      @filename = @id + "_text.mp3"
      @media =
        url: baseUrl + "/" + @filename
        base: baseUrl
        filename: @filename

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

      @server.on 'clientError', (err, socket) =>
        socket.end('HTTP/1.1 400 Bad Request\r\n\r\n')
        #env.logger.error "Error in serverClient: " + err

      Device = require('chromecast-api/lib/device')
      opts =
        name: @config.name
        host: @config.ip
      @gaDevice = new Device(opts)

      @gaDevice.on 'status', (status) =>
        env.logger.debug "cast device got status " + status.playerState

      super()

    destroy: ->
      @server.close()
      @gaDevice.close()
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
            return m.match('stop ', optional: yes)
              .matchDevice(soundsDevices, (m, d) ->
                # Already had a match with another device?
                if soundsDevice? and soundsDevice.id isnt d.id
                  context?.addError(""""#{input.trim()}" is ambiguous.""")
                  return
                soundType = "stop"
                soundsDevice = d
                match = m.getFullMatch()
              )
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
        switch @soundType
          when "text"
            env.logger.debug "Creating sound file... with text: " + @text
            @soundsDevice.gtts.save(@soundsDevice.soundsDir + "/" + @soundsDevice.filename, @text, (err) =>
              if err?
                return __("\"%s\" was not generated", @text)
              env.logger.debug "Sound generated, now casting " + @soundsDevice.media.url
              @soundsDevice.gaDevice.play(@soundsDevice.media.url, (err) =>
                if err?
                  env.logger.error 'error: ' + err
                  return __("\"%s\" was not played", @text)
                env.logger.debug 'Playing ' + @soundsDevice.media.url + " with volume " + @volume
                @soundsDevice.gaDevice.setVolume((Number @volume/100), (err) =>
                  if err?
                    env.logger.error "Error setting volume " + err
                    return __("\"%s\" was played but volume was not set", @text)
                  return __("\"%s\" was played with volume set", @text)
                )
              )
            )
          when "file"
            fullFilename = (@soundsDevice.media.base + "/" + @text)
            env.logger.debug "Playing sound file... " + fullFilename
            @soundsDevice.gaDevice.play(fullFilename, (err) =>
              if err?
                env.logger.error 'error: ' + err
                return __("\"%s\" was not played", err)
              env.logger.debug 'Playing ' + fullFilename + " with volume " + @volume
              @soundsDevice.gaDevice.setVolume((Number @volume/100), (err) =>
                if err?
                  env.logger.error "Error setting volume " + err
                  return __("\"%s\" was played but volume was not set", @text)
                return __("\"%s\" was played with volume set", @text)
              )
            )
          when "vol"
            @soundsDevice.gaDevice.setVolume((Number @volume/100), (err) =>
              if err?
                env.logger.error "Error setting volume " + err
                return __("\"%s\" was played but volume was not set", @text)
              return __("\"%s\" was played with volume set", @text)
            )
          when "stop"
            if @soundsDevice.gaDevice.client?
              @soundsDevice.gaDevice.stop((err) =>
                if err?
                  #env.logger.error "Error stopping track " + err
                  return __("\"%s\" nothing to stop", @text)
                return __("\"%s\" is stopped", @text)
              )
            return __("#{@soundsDevice.id} is stopped", @text)
          else
            env.logger.error 'error: unknown playtype'
            return __("\"%s\" unknown playtype", @soundType)

        return __("\"%s\" executed", @text)

    destroy: () ->

      super()

  soundsPlugin = new SoundsPlugin
  return soundsPlugin
