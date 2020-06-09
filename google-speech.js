
// Imports the Google Cloud client library
const textToSpeech = require('@google-cloud/text-to-speech');

// Import other required libraries
const fs = require('fs');
const util = require('util');

// Creates a client
async function save(client, options, filename, txt, callback) {
  // The text to synthesize
  //console.log("OPTIONS: " + JSON.stringify(options,null,2));
  const text = txt;
  const lang = options.language
  const voice = options.voice;
  const pitch = options.pitch;
  const speakingRate = options.speakingRate;
  // Construct the request
  const request = {
    //input: {text: text},
    input: {ssml: text},
    // Select the language and SSML voice gender (optional)
    voice: {languageCode: lang, name: voice, ssmlGender: 'NEUTRAL'},
    // select the type of audio encoding
    audioConfig: {audioEncoding: 'MP3', speakingRate: speakingRate, pitch: pitch},
  };
  
  // Performs the text-to-speech request
  const [response] = await client.synthesizeSpeech(request);
  // Write the binary audio content to a local file
  const writeFile = util.promisify(fs.writeFile);
  await writeFile(filename, response.audioContent, 'binary');
  //console.log('Audio content written to file: '+filename);
  callback(null);
}

function Text2Speech(_cred, _options, _debug) {
  //var lang = _lang || 'en-US';
  var debug = _debug || false;
  const email = _cred.email;
  var private_key = _cred.private_key;
  var options = _options
  private_key = private_key.replace(/\\n/gm, '\n');

  const client = new textToSpeech.TextToSpeechClient({
    credentials: { 
      client_email: email, 
      private_key: private_key 
    }
  });

  return {
    save: (filepath, text, callback) => save(client, options, filepath, text, callback)
  }
}

module.exports = Text2Speech;
