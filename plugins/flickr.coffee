_ = require('underscore')
passport = require('passport')
async = require('async')
http = require('http')
jade = require('jade')

FlickrStrategy = require('passport-flickr').Strategy
FlickrClient = require('flickr-with-uploads').Flickr;

base = require('./base')
models = require('../models')

BasePlugin = base.BasePlugin
PluginBackup = base.PluginBackup
File = require('../lib/file')
Symlink = require('../lib/symlink')

class FlickrPlugin extends BasePlugin

  routes: (app) ->
    app.get '/auth/flickr', @config, @auth
    app.get '/auth/flickr/callback', @auth, @redirect

  config: (req, res, next) =>
    config =
      consumerKey: CONFIG.keys.flickr.key
      consumerSecret: CONFIG.keys.flickr.secret
      callbackURL: "http://#{req.headers.host}/auth/flickr/callback"
    passport.use 'flickr-authz', new FlickrStrategy(config, @build)
    next()

  auth: passport.authorize('flickr-authz')

  build: (token, secret, profile, done) =>
    models.account.buildFromOAuth profile, token, secret, (err, account) =>
      if err
        done(err)
      else
        @backup(account)
        done(null, account)

  backup: (account, cb) =>
    new FlickrBackup(account).run(cb)

class FlickrBackup extends PluginBackup
  constructor: (@account) ->
    super(@account)
    @client = new FlickrClient(
      CONFIG.keys.flickr.key, CONFIG.keys.flickr.secret,
      @account.token, @account.secret
    )
    @client.get = (method, params, cb) ->
      params.api_key = CONFIG.keys.flickr.key;
      this.createRequest(method, params, true, cb).send()

  backup: (cb) =>
    @client.get 'flickr.people.getPhotos', {'user_id': @account.uid, 'extras': 'description, date_upload, tags'}, (err, data) =>        
      if err or not data?.photos?.photo?
        cb(err)
      else   
        i = 0
        async.forEachSeries data.photos.photo, @save, (err) =>
          i++
          if err
            cb(err)
          else if i < data.photos.total
            @backup(cb)
          else
            @account.save().complete(cb)

  save: (photo, cb) =>
    if photo.farm? && photo.server? && photo.id? && photo.secret?
      url = CONFIG.option 'flickr', 'static_url', photo 

      http.get url, (res) =>

        photo.image = "#{photo.id}.jpg"
        photo.path = "photos/#{photo.image}"

        image = new File @account, @snapshot, photo.path, false, res,
          title: photo.title
          description: photo.description._content
          tags: photo.tags

        image.save (err) =>
          if err
            console.log "#{photo.path} - error - #{err}"
          else
              console.log "#{photo.path} - saved"
              @incCount('added') if image.added
              @incCount('updated') if image.updated
              @symlink photo

          cb(err)          

  symlink: (photo) =>
    _write = (path, newPath) =>
      symlink = new Symlink @account, @snapshot, path, newPath
      symlink.save (err) =>
        if err
          console.log "#{newPath} - error - #{err}"
        else
          console.log "#{newPath} - symlink saved"

    if photo.tags?
      tags = photo.tags.split ' '
      for tag in tags
        _write photo.path, photo.path.replace(/^photos/, "tags/#{tag}")

module.exports = FlickrPlugin
FlickrPlugin.FlickrBackup = FlickrBackup