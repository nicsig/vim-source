fu source#op(...) abort "{{{1
    if !a:0
        let &opfunc = 'source#op'
        return 'g@'
    endif

    " Warning: If you run `:update`, don't forget `:lockm`.
    " Otherwise, the change marks would be unexpectedly reset.

    let type = a:0 == 1 ? a:1 : 'Ex'
    let [cb_save, sel_save]  = [&cb, &sel]
    let reg_save = getreginfo('"')

    try
        set cb-=unnamed cb-=unnamedplus sel=inclusive

        if type is# 'char'
            sil norm! `[v`]y
        elseif type is# 'line'
            sil norm! '[V']y
        elseif type is# 'block'
            sil exe "norm! `[\<c-v>`]y"
        elseif type is# 'Ex'
            sil exe a:1..','..a:2..'y'
        endif
        let lines = split(@", "\n")

    catch
        return lg#catch()

    finally
        let [&cb, &sel] = [cb_save, sel_save]
        call setreg('"', reg_save)
    endtry

    call filter(lines, {_,v -> v !~# '\~$\|[⇔→]\|^\s*[│─└┘┌┐]\|^[↣↢]\|^\s*\%(v\+\|\^\+\)\s*$'})
    if empty(lines) | return | endif
    call map(lines, {_,v -> substitute(v, '[✘✔┊].*', '', '')})
    call map(lines, {_,v -> substitute(v, '\C^\s*\%(fu\%[nction]\|com\%[mand]\)\zs\ze\s', '!', '')})
    let initial_indent = strlen(matchstr(lines[0], '^\s*'))
    " Why?{{{
    "
    " Here is the output of a sed command in the shell:
    "
    "     $ sed 's/\t/\
    "     /2' <<<'Column1	Column2	Column3	Column4'
    "     Column1	Column2~
    "     Column3	Column4~
    "
    " Here is the output of the same command when sourced with our plugin:
    "
    "     $ sed 's/\t/\
    "     /2' <<<'Column1	Column2	Column3	Column4'
    "     Column1 Column2~
    "         Column3     Column4~
    "
    " The indentation of the second line alters the output.
    " We must remove it to get the same result as in the shell.
    "}}}
    " Warning:{{{
    "
    " This can alter the result of a heredoc assignment.
    "
    " MWE:
    "
    "         let a =<< END
    "         xx
    "     END
    "     echo a
    "
    " If you run `:so%`, the output will be:
    "
    "     ['    xx']
    "       ^--^
    "
    " If you press `+sip`, the output will be:
    "
    "     ['xx']
    "
    " In practice, I doubt it will be an issue because I think we'll always use `trim`:
    "
    "                   v--v
    "         let a =<< trim END
    "         xx
    "     END
    "     echo a
    "}}}
    call map(lines, {_,v -> substitute(v, '^\s\{'..initial_indent..'}', '', '')})
    let tempfile = tempname()
    call writefile([''] + lines, tempfile, 'b')

    " we're sourcing a shell command
    let prompt = matchstr(lines[0], '^\s*\zs[$%]\ze\s')
    if prompt isnot# '' || s:is_in_embedded_shell_code_block()
        exe 'sp '..tempfile
        call source#fix_shell_cmd()
        q
        if prompt isnot# ''
            sil let @o = system({'$': 'bash', '%': 'zsh'}[prompt]..' '..tempfile)
        else
            sil let @o = system('bash '..tempfile)
        endif
        echo @o
        return
    endif

    " we're sourcing a vimL command
    try
        if type is# 'Ex'
            if exists(':ToggleEditingCommands') == 2
                ToggleEditingCommands 0
            endif

            let cmd = a:3..'verb source '..tempfile
            "         │
            "         └ use the verbosity level passed as an argument to `:SourceSelection`

        " the function was invoked via the mapping
        else
            let cmd = 'source '..tempfile
        endif

        " Flush any delayed screen updates before running `cmd`.
        " See `:h :echo-redraw`.
        redraw
        " save the output  in register `o` so we can  directly paste it wherever
        " we want; but remove the first newline before
        let @o = execute(cmd, '')[1:]
        " Don't run `:exe cmd`!{{{
        "
        " If you do, the code will be run twice (because you've just run `execute()`).
        " But if the code is not idempotent, the printed result may seem unexpected.
        " MWE:
        "
        "     let list = range(1, 4)
        "     call add(list, remove(list, 0))
        "     echo list
        "     [3, 4, 1, 2]~
        "
        " Here, the output should be:
        "
        "     [4, 1, 2, 3]~
        "}}}

        " Add the current  line to the history  to be able to  insert its output
        " into the buffer with `C-r X`.
        if type is# 'line' && line("'[") == line("']")
            call histadd(':', getline('.'))
        endif
    catch
        let @o = substitute(v:exception, '^Vim(.\{-}):', '', '')
        return lg#catch()
    finally
        if type is# 'Ex' && exists(':ToggleEditingCommands') == 2
            ToggleEditingCommands 1
        endif
    endtry
endfu

fu source#fix_shell_cmd() abort "{{{1
    let pos = getcurpos()

    " remove a possible dollar/percent sign in front of the command
    let pat = '^\%(\s*\n\)*\s*\zs[$%]\s\+'
    let lnum = search(pat)
    if lnum
        let text = substitute(getline(lnum), '^\s*\zs[$%]\s\+', '', '')
        call setline(lnum, text)
    endif

    " remove possible indentation in front of `EOF`
    let pat = '\C^\%(\s*EOF\)\n\='
    let lnum = search(pat)
    let line = getline(lnum)
    let indent = matchstr(line, '^\s*')
    let range = '1/<<.*EOF/;/^\s*EOF/'
    let mods = 'keepj keepp '
    if !empty(indent)
        sil exe mods..range..'s/^'..indent..'//e'
        sil exe mods..''']+s/^'..indent..')/)/e'
    endif

    " Remove empty lines at the top of the buffer.{{{
    "
    "     $ C-x C-e
    "     " press `o` to open a new line
    "     " insert `ls`
    "     " press `Esc` and `ZZ`
    "     # press Enter to run the command
    "     # press `M-c` to capture the pane contents via the capture-pane command from tmux
    "     " notice how `ls(1)` is not visible in the quickfix window
    "}}}
    " Why the autocmd?{{{
    "
    " To avoid some weird issue when starting Vim via `C-x C-e`.
    "
    "     :let @+ = "\n\x1b[201~\\n\n"
    "     # start a terminal other than xterm
    "     # press C-x C-e
    "     " enter insert mode and press C-S-v
    "     " keep pressing undo
    "
    " Vim keeps undoing new changes indefinitely.
    "
    "     :echo undotree()
    "     E724: variable nested too deep for displaying~
    "
    " MWE:
    "
    "     vim -Nu NONE \
    "       +'ino <c-m> <c-g>u<cr>' \
    "       +'let &t_PE = "\e[201~"' \
    "       +'au TextChanged * 1;/\S/-d' \
    "       +'let @+ = "\n\x1b[201~\\n\n"' \
    "       +startinsert
    "
    "     " press:  C-S-v Esc u u u ...
    "
    " To  avoid  this,   we  delay  the  deletion  until  we   leave  Vim  (yes,
    " `BufWinLeave` is fired when we leave Vim; but not `WinLeave`).
    "}}}
    if !exists('#fix_shellcmd') " no need to re-install the autocmd on every `TextChanged` or `InsertLeave`
        augroup fix_shellcmd | au!
            au BufWinLeave <buffer> ++once let s:abuf = str2nr(expand('<abuf>'))
               "\ find where the buffer is now
               \ | let s:winid = win_findbuf(s:abuf)
               "\ make sure we're in its window
               \ | if empty(s:winid) | exe 'b '..s:abuf | else | call win_gotoid(s:winid[0]) | endif
               "\ remove empty lines at the top
               \ | if getline(1) =~# '^\s*$' | keepp 1;/\S/-d_ | update | endif
        augroup END
    endif

    call setpos('.', pos)
endfu

fu s:is_in_embedded_shell_code_block() abort "{{{1
    let synstack = map(synstack(line('.'), col('.')), {_,v -> synIDattr(v, 'name')})
    return get(synstack, 0, '') =~# '^markdownHighlightz\=sh$'
endfu

fu source#fix_selection() abort "{{{1
    let tempfile = tempname()
    let selection = @*
    call writefile(split(selection, '\n'), tempfile)
    let s:star_save = getreginfo('*')
    let @* = ''
    call timer_start(0, {-> execute('so '..tempfile, '')})

    au CmdlineLeave * ++once call setreg('*', s:star_save) | unlet! s:star_save
endfu

