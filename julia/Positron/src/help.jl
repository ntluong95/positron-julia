# ---------------------------------------------------------------------------------------------
# Copyright (C) 2025 Posit Software, PBC. All rights reserved.
# Licensed under the Elastic License 2.0. See LICENSE.txt for license information.
# ---------------------------------------------------------------------------------------------

"""
Help service for Positron.

This module provides the Help pane functionality, displaying documentation
for Julia functions, types, and modules.
"""

using Markdown
using Sockets

const HELP_SERVER_MAX_PAGES = 128
const HELP_METHODS_MAX = 25

"""
The Help service manages the Help pane in Positron.
"""
mutable struct HelpService
    comm::Any  # PositronComm or test mock - using Any for testability
    server::Union{Sockets.TCPServer,Nothing}
    server_task::Union{Task,Nothing}
    server_port::Union{Int,Nothing}
    pages::Dict{String,String}
    page_order::Vector{String}
    pages_lock::ReentrantLock

    function HelpService()
        new(
            nothing,
            nothing,
            nothing,
            nothing,
            Dict{String,String}(),
            String[],
            ReentrantLock(),
        )
    end
end

"""
Initialize the help service with a comm.
"""
function init!(service::HelpService, comm::PositronComm)
    service.comm = comm

    on_msg!(comm, msg -> handle_help_msg(service, msg))
    on_close!(comm, () -> handle_help_close(service))
end

"""
Handle incoming messages on the help comm.
"""
function handle_help_msg(service::HelpService, msg::Dict)
    handle_with_logging("Help", service.comm, msg) do
        request = parse_help_request(msg)

        if request isa HelpShowHelpTopicParams
            handle_show_help_topic(service, request.topic)
        end
    end
end

"""
Handle help comm close.
"""
function handle_help_close(service::HelpService)
    stop_help_server!(service)
    service.comm = nothing
end

"""
Handle show_help_topic request - look up documentation and show it in Help pane.
"""
function handle_show_help_topic(service::HelpService, topic::String)
    if service.comm === nothing
        return
    end

    # Get help content for the topic
    content = get_help_content(topic)

    if content === nothing
        send_error(
            service.comm,
            JsonRpcErrorCode.INVALID_PARAMS,
            "No documentation found for: $topic",
        )
        return
    end

    url = publish_help_page!(service, topic, content)
    if url === nothing
        send_error(
            service.comm,
            JsonRpcErrorCode.INTERNAL_ERROR,
            "Unable to publish documentation for: $topic",
        )
        return
    end

    # Send success result first.
    send_result(service.comm, true)

    # Then send a URL-based show_help event (Positron Help pane expects URL kind).
    params = HelpShowHelpParams(url, ShowHelpKind_Url, true)
    send_event(service.comm, "show_help", params)
end

"""
Get help content for a topic.
"""
function get_help_content(topic::String)::Union{String,Nothing}
    # Try to resolve the symbol
    sym = resolve_symbol(topic)
    if sym === nothing
        return nothing
    end

    # Get documentation
    try
        doc_html = fetch_documentation_html(sym)
        if doc_html === nothing || isempty(doc_html)
            return nothing
        end

        doc_html = strip_internal_ref_links(doc_html)
        methods_html = render_methods_html(sym, topic)
        if methods_html === nothing
            return doc_html
        end

        return string(doc_html, methods_html)
    catch
        # Return nothing if help content can't be retrieved
        return nothing
    end
end

"""
Resolve a topic string to a Julia symbol.
"""
function resolve_symbol(topic::String)
    # Handle module-qualified names like "Base.sort"
    parts = split(topic, ".")

    try
        # Start from Main
        current = Main

        for (i, part) in enumerate(parts)
            sym = Symbol(part)

            if i == length(parts)
                # Final part - could be a function, type, or value
                if isdefined(current, sym)
                    return getfield(current, sym)
                end
            else
                # Intermediate part - should be a module
                if isdefined(current, sym)
                    val = getfield(current, sym)
                    if val isa Module
                        current = val
                    else
                        return nothing
                    end
                else
                    return nothing
                end
            end
        end
    catch
        return nothing
    end

    return nothing
end

"""
Fetch documentation for a symbol.
"""
function fetch_documentation(sym)::Union{String,Nothing}
    try
        # Resolve docs into markdown text so callers can post-process.
        doc = Base.Docs.doc(sym)

        if doc === nothing
            return nothing
        end

        return sprint(show, MIME("text/markdown"), doc)
    catch
        # Return nothing if documentation can't be fetched
        return nothing
    end
end

"""
Render documentation for a symbol as HTML.
"""
function fetch_documentation_html(sym)::Union{String,Nothing}
    try
        doc = Base.Docs.doc(sym)
        if doc === nothing
            return nothing
        end

        return sprint(show, MIME("text/html"), doc)
    catch
        # Fallback to markdown rendering if direct HTML rendering fails.
        md = fetch_documentation(sym)
        if md === nothing
            return nothing
        end
        return markdown_to_html(md)
    end
end

"""
Convert Markdown to HTML.
"""
function markdown_to_html(md_str::String)::String
    try
        # Parse markdown
        md = Markdown.parse(md_str)

        # Convert to HTML
        io = IOBuffer()
        show(io, MIME("text/html"), md)
        return String(take!(io))
    catch e
        # Fall back to plain text wrapped in pre
        return "<pre>$(escape_html(md_str))</pre>"
    end
end

"""
Strip unresolved internal `@ref` links from Julia doc HTML.
"""
function strip_internal_ref_links(html::String)::String
    replace(html, r"<a\s+href=\"@ref[^\"]*\">(.*?)</a>"s => s"\1")
end

"""
Render a compact methods section for function values.
"""
function render_methods_html(sym, topic::String)::Union{String,Nothing}
    if !(sym isa Function)
        return nothing
    end

    method_list = try
        collect(methods(sym))
    catch
        return nothing
    end

    total = length(method_list)
    if total == 0
        return nothing
    end

    shown = min(total, HELP_METHODS_MAX)
    io = IOBuffer()

    print(io, "<section class=\"julia-help-methods\">")
    print(io, "<h2>Methods</h2>")
    method_label = total == 1 ? "method" : "methods"
    print(
        io,
        "<p><code>",
        escape_html(topic),
        "</code> is a function with ",
        total,
        " ",
        method_label,
        ".</p>",
    )
    print(io, "<ol>")

    for i in 1:shown
        method = method_list[i]
        method_text = sprint(show, method)
        sig, location = split_method_display(method_text)

        print(io, "<li><code>", escape_html(sig), "</code>")
        if !isempty(location)
            print(io, " in <code>", escape_html(location), "</code>")
        end
        print(io, "</li>")
    end

    print(io, "</ol>")
    if shown < total
        print(io, "<p class=\"julia-help-note\">Showing ", shown, " of ", total, " methods.</p>")
    end
    print(io, "</section>")

    return String(take!(io))
end

"""
Split a method display string into signature and location sections.
"""
function split_method_display(method_text::String)::Tuple{String,String}
    parts = split(method_text, " @ ", limit = 2)
    if length(parts) == 2
        return (parts[1], parts[2])
    end
    return (method_text, "")
end

"""
Escape HTML special characters.
"""
function escape_html(s::String)::String
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    s = replace(s, "'" => "&#39;")
    return s
end

"""
Show help for a topic in the Help pane.
"""
function show_help!(service::HelpService, topic::String; focus::Bool = true)
    if service.comm === nothing
        return
    end

    content = get_help_content(topic)
    if content === nothing
        return
    end

    url = publish_help_page!(service, topic, content)
    if url === nothing
        return
    end

    params = HelpShowHelpParams(url, ShowHelpKind_Url, focus)
    send_event(service.comm, "show_help", params)
end

"""
Show help for a URL.
"""
function show_help_url!(service::HelpService, url::String; focus::Bool = true)
    if service.comm === nothing
        return
    end

    params = HelpShowHelpParams(url, ShowHelpKind_Url, focus)
    send_event(service.comm, "show_help", params)
end

"""
Create and publish a help page, returning a localhost URL.
"""
function publish_help_page!(
    service::HelpService,
    topic::String,
    html_content::String,
)::Union{String,Nothing}
    origin = ensure_help_server!(service)
    if origin === nothing
        return nothing
    end

    page_path = "/help/" * string(uuid4())
    page_html = wrap_help_html(topic, html_content)

    lock(service.pages_lock) do
        service.pages[page_path] = page_html
        push!(service.page_order, page_path)

        while length(service.page_order) > HELP_SERVER_MAX_PAGES
            stale = popfirst!(service.page_order)
            delete!(service.pages, stale)
        end
    end

    return string(origin, page_path)
end

"""
Start the local help HTTP server if needed and return its origin.
"""
function ensure_help_server!(service::HelpService)::Union{String,Nothing}
    if service.server !== nothing && isopen(service.server) && service.server_port !== nothing
        return "http://127.0.0.1:$(service.server_port)"
    end

    local server
    try
        server = Sockets.listen(ip"127.0.0.1", 0)
    catch
        return nothing
    end

    port = get_server_port(server)
    if port === nothing
        try
            close(server)
        catch
        end
        return nothing
    end

    service.server = server
    service.server_port = port
    service.server_task = @async run_help_server!(service, server)
    return "http://127.0.0.1:$port"
end

"""
Stop the local help HTTP server and clear cached pages.
"""
function stop_help_server!(service::HelpService)
    if service.server !== nothing
        try
            close(service.server)
        catch
        end
    end
    service.server = nothing
    service.server_task = nothing
    service.server_port = nothing

    lock(service.pages_lock) do
        empty!(service.pages)
        empty!(service.page_order)
    end
end

"""
Main accept loop for the help HTTP server.
"""
function run_help_server!(service::HelpService, server::Sockets.TCPServer)
    while isopen(server)
        socket = try
            Sockets.accept(server)
        catch
            break
        end

        @async begin
            try
                handle_help_http_client(service, socket)
            finally
                try
                    close(socket)
                catch
                end
            end
        end
    end
end

"""
Serve a single HTTP request for a help page.
"""
function handle_help_http_client(service::HelpService, socket::Sockets.TCPSocket)
    request_path = read_request_path(socket)
    if request_path === nothing
        write_http_response(
            socket,
            "400 Bad Request",
            "<h1>Bad Request</h1>";
            content_type = "text/html; charset=utf-8",
        )
        return
    end

    path_only = split(request_path, "?", limit = 2)[1]
    page_html = lock(service.pages_lock) do
        get(service.pages, path_only, nothing)
    end

    if page_html === nothing
        write_http_response(
            socket,
            "404 Not Found",
            "<h1>Help page not found</h1>";
            content_type = "text/html; charset=utf-8",
        )
        return
    end

    write_http_response(
        socket,
        "200 OK",
        page_html;
        content_type = "text/html; charset=utf-8",
    )
end

"""
Read and parse the HTTP request line and return the URL path.
"""
function read_request_path(socket::Sockets.TCPSocket)::Union{String,Nothing}
    request_line = try
        readline(socket)
    catch
        return nothing
    end

    parts = split(strip(request_line))
    if length(parts) < 2
        return nothing
    end
    request_path = parts[2]

    # Consume headers until blank line.
    while true
        header_line = try
            readline(socket)
        catch
            break
        end
        if isempty(strip(header_line))
            break
        end
    end

    return request_path
end

"""
Write an HTTP response.
"""
function write_http_response(
    socket::Sockets.TCPSocket,
    status::String,
    body::String;
    content_type::String = "text/plain; charset=utf-8",
)
    content_length = ncodeunits(body)
    response_headers = (
        "HTTP/1.1 $status\r\n" *
        "Content-Type: $content_type\r\n" *
        "Content-Length: $content_length\r\n" *
        "Cache-Control: no-store\r\n" *
        "Connection: close\r\n\r\n"
    )

    write(socket, response_headers)
    write(socket, body)
    flush(socket)
end

"""
Build a full HTML page around rendered help content.
"""
function wrap_help_html(topic::String, content_html::String)::String
    safe_title = escape_html(topic)
    return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$safe_title</title>
  <style>
    body {
      margin: 0;
      padding: 0;
    }

    .julia-help {
      max-width: 920px;
      margin: 0 auto;
      padding: 0.75rem 1rem 2rem 1rem;
    }

    .julia-help h1,
    .julia-help h2,
    .julia-help h3 {
      margin-top: 1.25rem;
      margin-bottom: 0.5rem;
      line-height: 1.25;
    }

    .julia-help p {
      margin: 0.75rem 0;
    }

    .julia-help code {
      font-size: 0.95em;
      background-color: var(--vscode-textCodeBlock-background, rgba(127, 127, 127, 0.2));
      border-radius: 4px;
      padding: 0.1rem 0.25rem;
    }

    .julia-help pre {
      border: 1px solid var(--vscode-panel-border, rgba(127, 127, 127, 0.35));
      border-radius: 6px;
      padding: 0.75rem;
      overflow-x: auto;
      background-color: var(--vscode-textCodeBlock-background, rgba(127, 127, 127, 0.2));
    }

    .julia-help pre code {
      background: transparent;
      border-radius: 0;
      padding: 0;
    }

    .julia-help ol {
      padding-left: 1.4rem;
      margin-top: 0.5rem;
    }

    .julia-help li {
      margin: 0.4rem 0;
    }

    .julia-help-methods {
      margin-top: 1.25rem;
      padding-top: 0.25rem;
      border-top: 1px solid var(--vscode-panel-border, rgba(127, 127, 127, 0.35));
    }

    .julia-help-note {
      color: var(--vscode-descriptionForeground, inherit);
      font-size: 0.95em;
    }
  </style>
</head>
<body>
  <main class="julia-help">
$content_html
  </main>
</body>
</html>
"""
end

"""
Get the bound port for a TCPServer.
"""
function get_server_port(server::Sockets.TCPServer)::Union{Int,Nothing}
    addr = Sockets.getsockname(server)
    if addr isa Tuple && length(addr) >= 2
        return Int(addr[2])
    end
    if hasproperty(addr, :port)
        return Int(getproperty(addr, :port))
    end
    return nothing
end
