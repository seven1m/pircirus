_ = require('underscore')
async = require('async')
passport = require('passport')
FacebookStrategy = require('passport-facebook').Strategy
graph = require('fbgraph')
https = require('https')
url = require('url')

base = require('./base')
BasePlugin = base.BasePlugin
PluginBackup = base.PluginBackup
models = require('../models')

class FacebookPlugin extends BasePlugin

  routes: (app) ->
    app.get '/auth/facebook', @config, @auth
    app.get '/auth/facebook/callback', @auth, @redirect

  config: (req, res, next) =>
    config =
      clientID: CONFIG.keys.facebook.client_id
      clientSecret: CONFIG.keys.facebook.client_secret
      callbackURL: "http://#{req.headers.host}/auth/facebook/callback"
    passport.use 'facebook-authz', new FacebookStrategy(config, @build)
    next()

  auth: passport.authorize('facebook-authz',
    scope: ['offline_access', 'user_photos', 'read_stream']
  )

  build: (accessToken, refreshToken, profile, done) =>
    models.account.buildFromOAuth2 profile, accessToken, refreshToken, (err, account) =>
      if err
        done(err)
      else
        @backup(account)
        done(null, account)

  backup: (account, cb) =>
    new FacebookBackup(account).run(cb)


class FacebookBackup extends PluginBackup

  constructor: (@account) ->
    super(@account)
    @client = graph
    @client.setAccessToken(@account.token)
    @until = @account.cursor if @account.cursor

  backup: (cb) =>
    params = {}
    params.until = @until if @until
    @client.get 'me/photos/uploaded', params, (err, res) =>
      if err
        cb(err)
      else
        if res.data and res.data.length > 0
          async.forEachSeries res.data, @save, (err) =>
            if err
              cb(err)
            else
              if (@until = @_findParam(res.paging?.next, 'until')) and (not @account.cursor or parseInt(@until) > parseInt(@account.cursor))
                @account.cursor = @until if parseInt(@until) > parseInt(@account.cursor)
                process.nextTick => @backup(cb)
              else
                @finish(cb)
        else
          @finish(cb)

  save: (data, cb) =>
    @client.get data.id, (err, res) =>
      if err
        if err.code == 100 # just a bad image, skip it
          cb()
        else
          cb(err)
      else
        console.log "retrieving #{data.id}..."
        path = "photos/#{data.id}.jpg"
        metaPath = "photos/#{data.id}.meta.json"
        uri = url.parse(res.source)
        req = https.request host: uri.host, port: uri.port, path: uri.path, (res) =>
          data.rev = data.updated_time
          data.updated = data.updated_time
          delete data.updated_time
          file = @newFile
            path: path
            data: res
            meta: data
          file.save (err) =>
            req.destroy() # FIXME this doesn't seem right, but the timeout fires if we don't destroy the req
            cb(err)
        req.setTimeout 10000, =>
          data.fail_count ?= 0
          console.log "timeout trying to retrieve Facebook photo (#{data.fail_count} failures): #{path}"
          req.destroy()
          if data.fail_count < 5
            data.fail_count++
            @save(data, cb)
          else
            cb("timeout trying to retreive photo #{path}")
        req.end()

  finish: (cb) =>
    @account.save().complete(cb)

  _findParam: (url, name) =>
    if url
      for pair in url.split('&')
        parts = pair.split('=')
        if parts[0] == name
          return parts[1]


module.exports = FacebookPlugin
FacebookPlugin.FacebookBackup = FacebookBackup
