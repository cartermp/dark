module Tests.BwdServer

open Expecto

open System.Threading.Tasks
open System.Net.Sockets
open System.Text.RegularExpressions
open FSharpPlus

open Prelude

module RT = LibExecution.RuntimeTypes
module PT = LibBackend.ProgramSerialization.ProgramTypes
module Routing = LibBackend.Routing

open TestUtils

let t name =
  testTask $"Httpfiles: {name}" {
    let canvasName = CanvasName.create $"test-{name}"
    do! TestUtils.clearCanvasData canvasName
    let toBytes (str : string) = System.Text.Encoding.ASCII.GetBytes str
    let toStr (bytes : byte array) = System.Text.Encoding.ASCII.GetString bytes

    let setHeadersToCRLF (text : byte array) : byte array =
      // We keep our test files with an LF line ending, but the HTTP spec
      // requires headers (but not the body, nor the first line) to have CRLF
      // line endings
      let mutable justSawNewline = false
      let mutable inBody = false

      text
      |> Array.toList
      |> List.collect
           (fun b ->
             if not inBody && b = byte '\n' then
               if justSawNewline then inBody <- true
               justSawNewline <- true
               [ byte '\r'; b ]
             else
               justSawNewline <- false
               [ b ])
      |> List.toArray

    let filename = $"tests/httptestfiles/{name}"
    let! contents = System.IO.File.ReadAllBytesAsync filename
    let contents = toStr contents

    let request, expectedResponse, httpDefs =
      // TODO: use FsRegex instead
      let options = System.Text.RegularExpressions.RegexOptions.Singleline

      let m =
        Regex.Match(
          contents,
          "^((\[http-handler \S+ \S+\]\n.*\n)+)\[request\]\n(.*)\[response\]\n(.*)$",
          options
        )

      if not m.Success then failwith $"incorrect format in {name}"
      let g = m.Groups

      (g.[3].Value |> toBytes |> setHeadersToCRLF,
       g.[4].Value |> toBytes |> setHeadersToCRLF,
       g.[2].Value)

    let handlers =
      Regex.Matches(httpDefs, "\[http-handler (\S+) (\S+)\]\n(.*)\n")
      |> Seq.toList
      |> List.map
           (fun m ->
             let progString = m.Groups.[3].Value
             let httpRoute = m.Groups.[2].Value
             let httpMethod = m.Groups.[1].Value

             let (source : PT.Expr) =
               progString |> FSharpToExpr.parse |> FSharpToExpr.convertToExpr

             let gid = Prelude.gid

             let ids : PT.Handler.ids =
               { moduleID = gid (); nameID = gid (); modifierID = gid () }

             PT.TLHandler
               { tlid = gid ()
                 pos = { x = 0; y = 0 }
                 ast = source
                 spec =
                   PT.Handler.HTTP(route = httpRoute, method = httpMethod, ids = ids) })

    let! ownerID = LibBackend.Account.userIDForUserName (UserName.create "test")

    let! canvasID =
      LibBackend.Canvas.canvasIDForCanvasName
        ownerID
        (CanvasName.create $"test-{name}")

    do!
      LibBackend.ProgramSerialization.SQL.saveHttpHandlersToCache
        canvasID
        ownerID
        handlers

    // Web server might not be loaded yet
    use client = new TcpClient()

    let mutable connected = false

    for i in 1 .. 10 do
      try
        if not connected then
          do! client.ConnectAsync("127.0.0.1", 10001)
          connected <- true
      with _ -> do! System.Threading.Tasks.Task.Delay 1000

    use stream = client.GetStream()
    stream.ReadTimeout <- 1000 // responses should be instant, right?

    do! stream.WriteAsync(request, 0, request.Length)

    let length = 10000
    let response = Array.zeroCreate length
    let! byteCount = stream.ReadAsync(response, 0, length)
    let response = Array.take byteCount response

    let response =
      FsRegEx.replace
        "Date: ..., .. ... .... ..:..:.. ..."
        "Date: XXX, XX XXX XXXX XX:XX:XX XXX"
        (toStr response)

    if String.startsWith "_" name then
      skiptest $"underscore test - {name}"
    else
      Expect.equal response (toStr expectedResponse) ""
  }

let testsFromFiles =
  // get all files
  let dir = "tests/httptestfiles/"

  System.IO.Directory.GetFiles(dir, "*")
  |> Array.map (System.IO.Path.GetFileName)
  |> Array.toList
  |> List.map t

let unitTests =
  [ testMany
      "sanitizeUrlPath"
      BwdServer.sanitizeUrlPath
      [ ("//", "/")
        ("/foo//bar", "/foo/bar")
        ("/abc//", "/abc")
        ("/abc/", "/abc")
        ("/abc", "/abc")
        ("/", "/")
        ("/abcabc//xyz///", "/abcabc/xyz")
        ("", "/") ]
    testMany
      "ownerNameFromHost"
      (fun cn ->
        cn
        |> CanvasName.create
        |> LibBackend.Account.ownerNameFromCanvasName
        |> fun (on : OwnerName.T) -> on.ToString())
      [ ("test-something", "test"); ("test", "test"); ("test-many-hyphens", "test") ]
    testMany
      "routeVariables"
      Routing.routeVariables
      [ ("/user/:userid/card/:cardid", [ "userid"; "cardid" ]) ]
    testMany2
      "routeInputVars"
      Routing.routeInputVars
      [ ("/hello/:name", "/hello/alice-bob", Some [ "name", RT.DStr "alice-bob" ])
        ("/hello/alice-bob", "/hello/", None)
        ("/user/:userid/card/:cardid",
         "/user/myid/card/0",
         Some [ "userid", RT.DStr "myid"; "cardid", RT.DStr "0" ])
        ("/a/:b/c/d", "/a/b/c/d", Some [ "b", RT.DStr "b" ])
        ("/a/:b/c/d", "/a/b/c", None)
        ("/a/:b", "/a/b/c/d", Some [ "b", RT.DStr "b/c/d" ])
        ("/:a/:b/:c",
         "/a/b/c/d/e",
         Some [ "a", RT.DStr "a"; "b", RT.DStr "b"; "c", RT.DStr "c/d/e" ])
        ("/a/:b/c/d", "/a/b/c/e", None)
        ("/letters:var", "lettersextra", None) ]
    testManyTask
      "canvasNameFromHost"
      (fun h ->
        h
        |> BwdServer.canvasNameFromHost
        |> Task.map (Option.map (fun cn -> cn.ToString())))
      [ ("test-something.builtwithdark.com", Some "test-something")
        ("my-canvas.builtwithdark.localhost", Some "my-canvas")
        ("builtwithdark.localhost", Some "builtwithdark")
        ("my-canvas.darkcustomdomain.com", Some "my-canvas")
        ("www.microsoft.com", None) ] ]

let tests =
  testList
    "BwdServer"
    [ testList "From files" testsFromFiles; testList "unit tests" unitTests ]

open Microsoft.AspNetCore.Hosting
// run our own webserver instead of relying on the dev webserver
let init () : Task =
  LibBackend.Init.init ()
  (BwdServer.webserver false 10001).RunAsync()
