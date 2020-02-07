module.exports = {
  title: "pimatic-sounds device config schemas"
  SoundsDevice: {
    title: "Sounds config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      ip:
        descpription: "the IP address of the Chromecast device"
        type: "string"
        required: true
      playInit:
        descpription: "Plays initSound.mp3 on (re)startup of device"
        type: "boolean"
        default: true
   }
}
