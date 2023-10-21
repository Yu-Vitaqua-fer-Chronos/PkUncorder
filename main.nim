{.define: ssl.}

import std/[
  threadpool,
  httpclient,
  strutils,
  sequtils,
  options,
  tables,
  rlocks,
  paths,
  json,
  uri,
  os
]

type
  Config* = object
    url_prefix*: string = ""
    output_folder*: string = "output"
    force_download*: bool = false
    output_system_json*: string = ""
    flat_folder*: bool = false
    regen_sysjson_only*: bool = false

  AvatarIndex* = object
    isFlat*: bool = false
    system*: Option[IndexSystem]
    groups*: Table[string, Option[IndexGroup]]
    members*: Table[string, Option[IndexMember]]
    cache*: seq[string]
    invalidUrls*: seq[string]

  IndexSystem* = object
    uuid*: string
    ext*: string

  IndexGroup* = object
    name*: string
    ext*: string

  IndexMember* = object
    name*: string
    ext*: string

  PkSystem* = object
    version*: int
    name*: string
    avatar_url*: string
    uuid*: string
    groups*: seq[PkGroup]
    members*: seq[PkMember]

  PkGroup* = object
    display_name*: string
    name*: string
    icon*: string
    uuid*: string

  PkMember* = object
    display_name*: string = ""
    name*: string = ""
    avatar_url*: string = ""
    uuid*: string = ""

const allowedFormatExt = ["png", "jpeg", "webp"]

let config: Config = parseFile("config.json").to(Config)

var
  validAvatarUUIDsLock = RLock()
  httpCounterLock = RLock()
  avatarIndexLock = RLock()
  usedUrlsLock = RLock()

  httpClients = newSeq[HttpClient](0)

  avatarCache {.guard: avatarIndexLock.} = newSeq[string](0)
  avatarIndex {.guard: avatarIndexLock.} : AvatarIndex

  validAvatarUUIDs {.guard: validAvatarUUIDsLock.} = newSeq[string](0)
  usedUrls {.guard: usedUrlsLock.} = newSeq[string](0)
  sysjson = parseJson(readFile("system.json"))
  system = sysjson.to(PkSystem)

  httpCounter {.guard: httpCounterLock.} = 0

try:
  avatarIndex = parseFile(config.output_folder / "index.json").to(AvatarIndex)
except IOError:
  avatarIndex = AvatarIndex(isFlat: config.flat_folder)

initRLock(validAvatarUUIDsLock)
initRLock(httpCounterLock)
initRLock(avatarIndexLock)
initRLock(usedUrlsLock)

for i in 0..7:
  httpClients.add newHttpClient()

let httpClientsLen = httpClients.len

proc ifFlatFolder(s: string): string {.gcsafe.} = {.cast(gcsafe).}:
  withRLock(avatarIndexLock):
    result = if avatarIndex.isFlat: "" else: s

proc shouldSkip(s: PkSystem): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = (config.force_download)

    withRLock(avatarIndexLock):
      result = result or (s.avatar_url in avatarIndex.cache) or (s.avatar_url in avatarIndex.invalidUrls)

proc shouldSkip(g: PkGroup): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = (config.force_download)

    withRLock(avatarIndexLock):
      result = result or (g.icon in avatarIndex.cache) or (g.icon in avatarIndex.invalidUrls)

proc shouldSkip(m: PkMember): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = (config.force_download)

    withRLock(avatarIndexLock):
      result = result or (m.avatar_url in avatarIndex.cache) or (m.avatar_url in avatarIndex.invalidUrls)

proc getPkFileExt(s: string): string =
  let linkUri = parseUri(s)

  var split = linkUri.path.split(".")
  result = if split.len > 1: split[^1] else: ""

  let queries = linkUri.query.decodeQuery().toSeq()

  for query in queries:
    if query.key == "format":
      result = if query.value in allowedFormatExt: query.value else: result

proc getHttpClient(): int =
  withRLock(httpCounterLock):
    if httpCounter >= httpClientsLen:
      httpCounter = 0

    inc httpCounter

    return httpCounter - 1

proc handleGroup(client: HttpClient, group: PkGroup) {.gcsafe.} =
  withRLock(usedUrlsLock):
    if group.icon != "":
      {.cast(gcsafe).}:
        usedUrls.add group.icon

  let fileExt = group.icon.getPkFileExt()

  if group.shouldSkip():
    return

  echo "Downloading " & group.name & "'s avatar..."

  try:
    {.cast(gcsafe).}:
      var groupCacheUrl = parseUri(config.url_prefix)

    var removeScheme = false

    if groupCacheUrl.scheme == "":
      removeScheme = true

      groupCacheUrl.scheme = "http"

    groupCacheUrl = groupCacheUrl / "g".ifFlatFolder / (group.uuid & '.' & fileExt)

    groupCacheUrl.scheme = ""

    {.cast(gcsafe).}:
      client.downloadFile(group.icon, joinPath(config.output_folder, 
        "g".ifFlatFolder, group.uuid & '.' & fileExt))

    withRLock(avatarIndexLock):
      {.cast(gcsafe).}:
        withRLock(validAvatarUUIDsLock):
          validAvatarUUIDs.add group.uuid

        avatarIndex.groups[group.uuid] = IndexGroup(
          name: group.name,
          ext: fileExt
        ).some

        avatarCache.add $groupCacheUrl

  except HttpRequestError:
    echo "Couldn't download " & group.name & "'s icon!"

    withRLock(avatarIndexLock):
      if group.icon != "":
        {.cast(gcsafe).}:
          avatarIndex.invalidUrls.add group.icon

    return

  except ValueError:
    echo "Couldn't download " & group.name & "'s icon!"

    withRLock(avatarIndexLock):
      if group.icon != "":
        {.cast(gcsafe).}:
          avatarIndex.invalidUrls.add group.icon

    return

proc handleMember(client: HttpClient, member: PkMember) {.gcsafe.} =
  withRLock(usedUrlsLock):
    if member.avatar_url != "":
      {.cast(gcsafe).}:
        usedUrls.add member.avatar_url

  let fileExt = member.avatar_url.getPkFileExt()

  if member.shouldSkip():
    return

  echo "Downloading " & member.name & "'s avatar..."

  try:
    {.cast(gcsafe).}:
      client.downloadFile(member.avatar_url, joinPath(config.output_folder, 
        "m".ifFlatFolder, member.uuid & '.' & fileExt))

      var memberCacheUrl = parseUri(config.url_prefix)

    var removeScheme = false

    if memberCacheUrl.scheme == "":
      removeScheme = true

      memberCacheUrl.scheme = "http"

    memberCacheUrl = memberCacheUrl / "m".ifFlatFolder / (member.uuid & '.' & fileExt)

    memberCacheUrl.scheme = ""

    withRLock(avatarIndexLock):
      {.cast(gcsafe).}:
        withRLock(validAvatarUUIDsLock):
          validAvatarUUIDs.add member.uuid

        avatarIndex.members[member.uuid] = IndexMember(
          name: member.name,
          ext: fileExt
        ).some

        avatarCache.add $memberCacheUrl

  except HttpRequestError:
    echo "Couldn't download " & member.name & "'s avatar!"

    withRLock(avatarIndexLock):
      if member.avatar_url != "":
        {.cast(gcsafe).}:
          avatarIndex.invalidUrls.add member.avatar_url

    return

  except ValueError:
    echo "Couldn't download " & member.name & "'s icon!"

    withRLock(avatarIndexLock):
      if member.avatar_url != "":
        {.cast(gcsafe).}:
          avatarIndex.invalidUrls.add member.avatar_url

    return

proc generateNewSystemJson() =
  var urlBase = parseUri(config.url_prefix)

  var removeScheme = false

  if urlBase.scheme == "":
    urlBase.scheme = "http"

    removeScheme = true

  withRLock(avatarIndexLock):
    if avatarIndex.system.isSome:
      sysjson["avatar_url"] = newJString(
        $(urlBase / (avatarIndex.system.get().uuid & '.' & avatarIndex.system.get().ext))
      )

    for uuid in avatarIndex.groups.keys:
      withRLock(validAvatarUUIDsLock):
        if (uuid in validAvatarUUIDs) and (avatarIndex.groups[uuid].isSome):
          let
            group = avatarIndex.groups[uuid].get()
            groupsLen = sysjson["groups"].len

          var counter = 0

          while counter < groupsLen:
            if sysjson["groups"][counter]["uuid"].getStr() != uuid:
              sysjson["groups"][counter]["icon"] = ("g".ifFlatFolder / uuid & '.' & group.ext).newJString()

            inc counter

    for uuid in avatarIndex.members.keys:
      withRLock(validAvatarUUIDsLock):
        if (uuid in validAvatarUUIDs) and (avatarIndex.members[uuid].isSome):
          let
            member = avatarIndex.members[uuid].get()
            membersLen = sysjson["members"].len

          var counter = 0

          while counter < membersLen:
            if sysjson["members"][counter]["uuid"].getStr() != uuid:
              sysjson["members"][counter]["avatar_url"] = ("m".ifFlatFolder / uuid & '.' & member.ext).newJString()

            inc counter

  writeFile(config.output_system_json, $sysjson)

proc main =
  if not config.regen_sysjson_only:
    if system.version != 2:
      echo "This program only supports `system.json`s V2 format!"
      quit(1)

    createDir(config.output_folder)
    createDir(config.output_folder / "g")
    createDir(config.output_folder / "m")

    let groups = system.groups
    let members = system.members

    var sysAvatarExt: string

    withRLock(validAvatarUUIDsLock):
      validAvatarUUIDs = newSeqOfCap[string](groups.len + members.len + 1)

    withRLock(avatarIndexLock):
      avatarCache = newSeqOfCap[string](groups.len + members.len + 1)

      if not (system.shouldSkip()):
        var systemCacheUri = parseUri(config.url_prefix)

        var removeScheme = false

        if systemCacheUri.scheme == "":
          removeScheme = true

          systemCacheUri.scheme = "http"

        systemCacheUri = systemCacheUri / (system.uuid & '.' & sysAvatarExt)

        systemCacheUri.scheme = ""

        try:
          echo "Downloading the system's avatar..."

          withRLock(usedUrlsLock):
            usedUrls.add system.avatar_url

          sysAvatarExt = system.avatar_url.getPkFileExt()

          httpClients[getHttpClient()].downloadFile(system.avatar_url,
            joinPath(config.output_folder, system.uuid & '.' & sysAvatarExt))

          withRLock(avatarIndexLock):
            avatarCache.add $systemCacheUri

          withRLock(validAvatarUUIDsLock):
            validAvatarUUIDs.add system.uuid

          avatarIndex.system = IndexSystem(uuid: system.uuid,
            ext: sysAvatarExt).some()

        except HttpRequestError:
          echo "Couldn't download the system's avatar!"

          withRLock(usedUrlsLock):
            if system.avatar_url != "":
              avatarIndex.invalidUrls.add system.avatar_url

          return

        except ValueError:
          echo "Couldn't download the system's icon!"

          withRLock(usedUrlsLock):
            if system.avatar_url != "":
              avatarIndex.invalidUrls.add system.avatar_url

          return

    var counter = 0

    for group in groups:
      if counter >= httpClients.len:
        sync()

      spawn handleGroup(httpClients[getHttpClient()], group)

      inc counter

    counter = 0

    for member in members:
      if counter >= httpClients.len:
        sync()

      spawn handleMember(httpClients[getHttpClient()], member)

      inc counter

    withRLock(avatarIndexLock):
      avatarIndex.cache = avatarCache

      writeFile(config.output_folder / "index.json", pretty(%avatarIndex))

      withRLock(usedUrlsLock):
        let iUrls = avatarIndex.invalidUrls
        for url in iUrls:
          if url notin usedUrls:
            var counter = 0

            while counter < avatarIndex.invalidUrls.len:
              if avatarIndex.invalidUrls[counter] == url:
                avatarIndex.invalidUrls.del counter

              inc counter

    echo "Finished downloading all avatars!"

  else:
    withRLock(avatarIndexLock):
      withRLock(validAvatarUUIDsLock):
        validAvatarUUIDs = newSeqOfCap[string](avatarIndex.cache.len)

        for url in avatarIndex.cache:
          validAvatarUUIDs.add splitFile(url.Path).name.string

  echo "Generating new system.json..."

  generateNewSystemJson()

  echo "Generated new system.json at `" & config.output_system_json & "`!"

main()