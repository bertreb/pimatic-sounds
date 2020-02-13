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
}
