module.exports = {
  title: "pimatic-sounds device config schemas"
  ChromecastDevice: {
    title: "ChromecastDevice config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      ip:
        descpription: "The IP address of the Chromecast device"
        type: "string"
        required: true
      port:
        descpription: "The port number for the Chromecast service. Is set automatically"
        type: "number"
        default: 8009
      playInit:
        descpription: "Plays initSound.mp3 on (re)startup of device"
        type: "boolean"
        default: true
  }
  SonosDevice: {
    title: "SonosDevice config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      ip:
        descpription: "The IP address of the Sonos device"
        type: "string"
        required: true
      playInit:
        descpription: "Plays initSound.mp3 on (re)startup of device"
        type: "boolean"
        default: true
  }
  GroupDevice: {
    title: "GroupDevice config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      devices:
        description: "Sounds devices"
        type: "array"
        default: []
        format: "table"
        items:
          type: "object"
          required: ["name"]
          properties:
            name:
              description: "Name of the Sounds Devices."
              type: "string"
              enum: []
  }
}
