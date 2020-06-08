# #pimatic-sounds configuration options
module.exports = {
  title: "pimatic-sounds configuration options"
  type: "object"
  properties:
  	port:
  	  descpription: "The port number of the chromecast device"
  	  type: "number"
  	  default: 8088
  	language:
  	  descpription: "The language used in text-to-speech"
  	  type: "string"
  	  default: "en"
    debug:
      description: "Debug mode. Writes debug messages to the pimatic log, if set to true."
      type: "boolean"
      default: false
    tts:
      description: "the tss engine to be used"
      enum: ["google-translate","google-cloud"]
      default: "google-translate"
    googleCloudJson:
      description: "The filename of the Google Cloud credential file"
      type: "string"
      required: false
}
