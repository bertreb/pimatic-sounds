module.exports = {
  title: "pimatic-sounds device config schemas"
  SoundsDevice: {
    title: "Sounds config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      name:
        descpription: "The name of the Chromecast device"
        type: "string"
        required: true
      ip:
        descpription: "the IP address of the chromecast device"
        type: "string"
        required: true
  }
}
