{.define: ssl.}

import std/[
  threadpool,
  httpclient,
  strutils,
  sequtils,
  tables,
  rlocks,
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

  AvatarIndex* = object
    system*: IndexSystem
    groups*: Table[string, IndexGroup]
    members*: Table[string, IndexMember]
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
  httpCounterLock = RLock()
  avatarIndexLock = RLock()
  usedUrlsLock = RLock()

  httpClients = newSeq[HttpClient](0)

  avatarCache {.guard: avatarIndexLock.} = newSeq[string](0)
  avatarIndex {.guard: avatarIndexLock.} : AvatarIndex

  usedUrls {.guard: usedUrlsLock.} = newSeq[string](0)
  sysjson = parseJson(readFile("system.json"))
  system = sysjson.to(PkSystem)

  httpCounter {.guard: httpCounterLock.} = 0

try:
  avatarIndex = parseFile(config.output_folder / "index.json").to(AvatarIndex)
except IOError:
  avatarIndex = AvatarIndex()

initRLock(httpCounterLock)
initRLock(avatarIndexLock)
initRLock(usedUrlsLock)

for i in 0..7:
  httpClients.add newHttpClient()

let httpClientsLen = httpClients.len

template ifFlatFolder(s: string): string = (if config.flat_folder: "" else: s)

proc shouldSkip(s: PkSystem): bool =
  result = (config.force_download)

  withRLock(avatarIndexLock):
    result = result or (s.avatar_url in avatarIndex.cache) or (s.avatar_url in avatarIndex.invalidUrls)

proc shouldSkip(g: PkGroup): bool =
  result = (config.force_download)

  withRLock(avatarIndexLock):
    result = result or (g.icon in avatarIndex.cache) or (g.icon in avatarIndex.invalidUrls)

proc shouldSkip(m: PkMember): bool =
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

proc handleGroup(client: HttpClient, group: PkGroup) =
  withRLock(usedUrlsLock):
    if group.icon != "":
      usedUrls.add group.icon

  let fileExt = group.icon.getPkFileExt()

  if group.shouldSkip():
    return

  echo "Downloading " & group.name & "'s avatar..."

  try:
    var groupCacheUrl = parseUri(config.url_prefix)

    var removeScheme = false

    if groupCacheUrl.scheme == "":
      removeScheme = true

      groupCacheUrl.scheme = "http"

    groupCacheUrl = groupCacheUrl / "g".ifFlatFolder / (group.uuid & '.' & fileExt)

    groupCacheUrl.scheme = ""

    client.downloadFile(group.icon, joinPath(config.output_folder, 
      "g".ifFlatFolder, group.uuid & '.' & fileExt))

    withRLock(avatarIndexLock):
      avatarIndex.groups[group.uuid] = IndexGroup(
        name: group.name,
        ext: fileExt
      )

      avatarCache.add $groupCacheUrl

  except HttpRequestError:
    echo "Couldn't download " & group.name & "'s icon!"

    withRLock(avatarIndexLock):
      if group.icon != "":
        avatarIndex.invalidUrls.add group.icon

    return

  except ValueError:
    echo "Couldn't download " & group.name & "'s icon!"

    withRLock(avatarIndexLock):
      if group.icon != "":
        avatarIndex.invalidUrls.add group.icon

    return

proc handleMember(client: HttpClient, member: PkMember) =
  withRLock(usedUrlsLock):
    if member.avatar_url != "":
      usedUrls.add member.avatar_url

  let fileExt = member.avatar_url.getPkFileExt()

  if member.shouldSkip():
    return

  echo "Downloading " & member.name & "'s avatar..."

  try:
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
      avatarIndex.members[member.uuid] = IndexMember(
        name: member.name,
        ext: fileExt
      )

      avatarCache.add $memberCacheUrl

  except HttpRequestError:
    echo "Couldn't download " & member.name & "'s avatar!"

    withRLock(avatarIndexLock):
      if member.avatar_url != "":
        avatarIndex.invalidUrls.add member.avatar_url

    return

  except ValueError:
    echo "Couldn't download " & member.name & "'s icon!"

    withRLock(avatarIndexLock):
      if member.avatar_url != "":
        avatarIndex.invalidUrls.add member.avatar_url

    return

proc main =
  createDir(config.output_folder)
  createDir(config.output_folder / "g")
  createDir(config.output_folder / "m")

  let groups = system.groups
  let members = system.members

  var sysAvatarExt: string

  withRLock(avatarIndexLock):
    avatarCache = newSeqOfCap[string](groups.len + members.len + 1)

    if not (system.shouldSkip()):
      sysAvatarExt = system.avatar_url.getPkFileExt()

      avatarIndex.system = IndexSystem(uuid: system.uuid,
        ext: sysAvatarExt)

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

      httpClients[getHttpClient()].downloadFile(system.avatar_url,
        joinPath(config.output_folder, system.uuid & '.' & sysAvatarExt))

      withRLock(avatarIndexLock):
        avatarCache.add $systemCacheUri

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

    spawn cast[proc(a: HttpClient, b: PkGroup) {.gcsafe, nimcall.}](handleGroup)(httpClients[getHttpClient()], group)

    inc counter

  counter = 0

  for member in members:
    if counter >= httpClients.len:
      sync()

    spawn cast[proc(a: HttpClient, b: PkMember) {.gcsafe, nimcall.}](handleMember)(httpClients[getHttpClient()], member)

    inc counter

  withRLock(avatarIndexLock):
    avatarIndex.cache = avatarCache

  withRLock(avatarIndexLock):
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

main()