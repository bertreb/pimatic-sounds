'use strict';

function getContentType(fileName) {
const contentTypeMap = {
    "3gp": "video/3gpp",
    aac: "video/mp4",
    aif: "audio/x-aiff",
    aiff: "audio/x-aiff",
    aifc: "audio/x-aiff",
    avi: "video/x-msvideo",
    au: "audio/basic",
    bmp: "image/bmp",
    flv: "video/x-flv",
    gif: "image/gif",
    ico: "image/x-icon",
    jpe: "image/jpeg",
    jpeg: "image/jpeg",
    jpg: "image/jpeg",
    m3u: "audio/x-mpegurl",
    m3u8: "application/x-mpegURL",
    m4a: "audio/mp4",
    mid: "audio/mid",
    midi: "audio/mid",
    mov: "video/quicktime",
    movie: "video/x-sgi-movie",
    mpa: "audio/mpeg",
    mp2: "audio/x-mpeg",
    mp3: "audio/mp3",
    mp4: "audio/mp4",
    mjpg: "video/x-motion-jpeg",
    mjpeg: "video/x-motion-jpeg",
    mpe: "video/mpeg",
    mpeg: "video/mpeg",
    mpg: "video/mpeg",
    ogg: "audio/ogg",
    ogv: "audio/ogg",
    png: "image/png",
    qt: "video/quicktime",
    ra: "audio/vnd.rn-realaudio",
    ram: "audio/x-pn-realaudio",
    rmi: "audio/mid",
    rpm: "audio/x-pn-realaudio-plugin",
    snd: "audio/basic",
    stream: "audio/x-qt-stream",
    svg: "image/svg",
    tif: "image/tiff",
    tiff: "image/tiff",
    vp8: "video/webm",
    wav: "audio/vnd.wav",
    webm: "video/webm",
    webp: "image/webp",
    wmv: "video/x-ms-wmv"
  };
  var ext = fileName.split(".").slice(-1)[0];
  var contentType = contentTypeMap[ext.toLowerCase()];

  return contentType || "audio/basic";
};

module.exports = getContentType;
