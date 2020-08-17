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
    voice:
      description: "The name of the voice, format is <language-code>-Standard-[A,B,C,D]"
      type: "string"
      required: false
    pitch:
      description: "The increase or decrease in semitones of the voice pitch (-20 to +20)"
      type: "number"
      required: false
    speakingRate:
      description: "The speed of the voice (0.25 to 4.0)"
      type: "number"
      required: false
    assistantRelay:
      description: "Enable to use for GoogleDevice (if assistant-relay is installed)"
      type: "boolean"
      default: false
    assistantRelayIp:
      description: "The IP address of the assistant-relay server"
      type: "string"
    assistantRelayPort:
      description: "The Port number of the assistant-relay server"
      type: "number"
      default: 3000
    assistantRelayUser:
      description: "The username for assistant-relay"
      type: "string"
      default: ""
}
