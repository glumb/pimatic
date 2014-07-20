###
Plugin Manager
=======
###

Promise = require 'bluebird'
fs = require 'fs'; Promise.promisifyAll(fs)
path = require 'path'
util = require 'util'
assert = require 'cassert'
byline = require 'byline'
_ = require 'lodash'
spawn = require("child_process").spawn
https = require "https"
semver = require "semver"
events = require 'events'
S = require 'string'

module.exports = (env) ->

  class PluginManager extends events.EventEmitter

    updateProcessStatus: 'idle'
    updateProcessMessages: []

    constructor: (@framework) ->
      @modulesParentDir = path.resolve @framework.maindir, '../../'

    # Loads the given plugin by name
    loadPlugin: (name) ->
      packageInfo = @getInstalledPackageInfo(name)
      packageInfoStr = (if packageInfo? then "(" + packageInfo.version  + ")" else "")
      env.logger.info("""loading plugin: "#{name}" #{packageInfoStr}""")
      # require the plugin and return it
      # create a sublogger:
      pluginEnv = Object.create(env)
      pluginEnv.logger = env.logger.base.createSublogger(name)
      plugin = (require name) pluginEnv, module
      return Promise.resolve([plugin, packageInfo])

    # Checks if the plugin folder exists under node_modules
    isInstalled: (name) ->
      assert name?
      assert name.match(/^pimatic-.*$/)?
      return fs.existsSync(@pathToPlugin name)

    # Install a plugin from the npm repository
    installPlugin: (name) ->
      assert name?
      assert name.match(/^pimatic-.*$/)?
      return @spawnNpm(['install', name])

    _emitUpdateProcessStatus: (status, info) ->
      @emit 'updateProcessStatus', status, info

    _emitUpdateProcessMessage: (message, info) ->
      @emit 'updateProcessMessages', message, info

    update: (modules) -> 
      @_emitUpdateProcessStatus('running', {modules})

      return @spawnNpm(['update'].concat modules).then( onDone = ( =>
        @_emitUpdateProcessStatus('done', {modules})
        return modules
      ), onError = ( (error) =>
        @_emitUpdateProcessStatus('error', {modules})
        throw error
      ), onProgress = ( (message) =>
        @_emitUpdateProcessMessage(message, {modules})
      ))

    pathToPlugin: (name) ->
      assert name?
      assert name.match(/^pimatic-.*$/)? or name is "pimatic"
      return path.resolve @framework.maindir, "..", name

    searchForPlugins: ->
      plugins = [ 
        'pimatic-cron',
        'pimatic-datalogger',
        'pimatic-filebrowser',
        'pimatic-gpio',
        'pimatic-log-reader',
        'pimatic-mobile-frontend',
        'pimatic-pilight',
        'pimatic-ping',
        'pimatic-redirect',
        'pimatic-rest-api',
        'pimatic-shell-execute',
        'pimatic-sispmctl',
        "pimatic-pushover",
        "pimatic-sunrise",
        "pimatic-voice-recognition"
      ]
      waiting = []
      found = {}
      for p in plugins
        do (p) =>
          waiting.push @getNpmInfo(p).then( (info) =>
            found[p] = info
          )
      return Promise.allSettled(waiting).then( (results) =>
        env.logger.error(r.reason) for r in results when r.state is "rejected"
        return found
      ).catch( (e) => env.logger.error e )

    searchForPluginsWithInfo: ->
      return @searchForPlugins().then( (plugins) =>
        return pluginList = (
          for k, p of plugins 
            name = p.name.replace 'pimatic-', ''
            loadedPlugin = @framework.getPlugin name
            installed = @isInstalled p.name
            packageJson = (
              if installed then @getInstalledPackageInfo p.name
              else null
            )
            listEntry = {
              name: name
              description: p.description
              version: p.version
              installed: installed
              active: loadedPlugin?
              isNewer: (if installed then semver.gt(p.version, packageJson.version) else false)
            }
        )
      )

    isPimaticOutdated: ->
      installed = @getInstalledPackageInfo("pimatic")
      return @getNpmInfo("pimatic").then( (latest) =>
        if semver.gt(latest.version, installed.version)
          return {
            current: installed.version
            latest: latest.version
          }
        else return false
      )

    getOutdatedPlugins: ->
      return @getInstalledPluginUpdateVersions().then( (result) =>
        outdated = []
        for i, p of result
          if semver.gt(p.latest, p.current)
            outdated.push p
        return outdated
      )

    getInstalledPluginUpdateVersions: ->
      return @getInstalledPlugins().then( (plugins) =>
        waiting = []
        infos = []
        for p in plugins
          do (p) =>
            installed = @getInstalledPackageInfo(p)
            waiting.push @getNpmInfo(p).then( (latest) =>
              infos.push {
                plugin: p
                current: installed.version
                latest: latest.version
              }
            )
        return Promise.allSettled(waiting).then( (results) =>
          env.logger.error(r.reason) for r in results when r.state is "rejected"

          ret = []
          for info in infos
            unless info.current?
              env.logger.warn "Could not get installed package version of #{info.plugin}"
              continue
            unless info.latest?
              env.logger.warn "Could not get latest version of #{info.plugin}"
              continue
            ret.push info
          return ret
        )
      )

    spawnNpm: (args) ->
      return new Promise( (resolve, reject) =>
        if @npmRunning
          reject "npm is currently in use"
          return
        @npmRunning = yes
        output = ''
        npm = spawn('npm', args, cwd: @modulesParentDir)
        stdout = byline(npm.stdout)
        npmLogger = env.logger.createSublogger("npm")
        stdout.on "data", (line) => 
          line = line.toString()
          output += "#{line}\n"
          if line.indexOf('npm http 304') is 0 then return
          npmLogger.info S(line).chompLeft('npm ').s
        stderr = byline(npm.stderr)
        stderr.on "data", (line) => 
          line = line.toString()
          output += "#{line}\n"
          npmLogger.info S(line).chompLeft('npm ').s

        npm.on "close", (code) =>
          @npmRunning = no
          command = "npm " + _.reduce(args, (akk, a) -> "#{akk} #{a}")
          if code isnt 0
            reject new Error("Error running \"#{command}\"")
          else resolve(output)

      )

    getInstalledPlugins: ->
      return fs.readdirAsync("#{@framework.maindir}/..").then( (files) =>
        return plugins = (f for f in files when f.match(/^pimatic-.*/)?)
      )

    getInstalledPluginsWithInfo: ->
      return @getInstalledPlugins().then( (plugins) =>
        return pluginList = (
          for name in plugins
            packageJson = @getInstalledPackageInfo name
            name = name.replace 'pimatic-', ''
            loadedPlugin = @framework.getPlugin name
            listEntry = {
              name: name
              active: loadedPlugin?
              description: packageJson.description
              version: packageJson.version
              homepage: packageJson.homepage
            }
        )
      )

    installUpdatesAsync: (modules) ->
      return new Promise( (resolve, reject) =>
        # resolve when complete
        @update(modules).then(resolve)
        # or after 10 seconds to prevent a timeout
        Promise.delay('still running', 10000).then(resolve)
      )

    getInstalledPackageInfo: (name) ->
      assert name?
      assert name.match(/^pimatic-.*$/)? or name is "pimatic"
      return JSON.parse fs.readFileSync(
        "#{@pathToPlugin name}/package.json", 'utf-8'
      )

    getNpmInfo: (name) ->
      return new Promise( (resolve, reject) =>
        https.get("https://registry.npmjs.org/#{name}/latest", (res) =>
          str = ""
          res.on "data", (chunk) -> str += chunk
          res.on "end", ->
            try
              info = JSON.parse(str)
              if info.error?
                throw new Error("getting info about #{name} failed: #{info.reason}")
              resolve info
            catch e
              reject e.message
        ).on "error", reject
      )


  class Plugin extends require('events').EventEmitter
    name: null
    init: ->
      throw new Error("your plugin must implement init")

    #createDevice: (config) ->

  return exports = {
    PluginManager
    Plugin
  }