fu! source#op(type, ...) abort
    let cb_save  = &cb
    let sel_save = &selection
    let reg_save = [ '"', getreg('"'), getregtype('"') ]

    try
        set cb-=unnamed cb-=unnamedplus
        set selection=inclusive

        if a:type is# 'char'
            sil norm! `[v`]y
        elseif a:type is# 'line'
            sil norm! '[V']y
        elseif a:type is# 'block'
            sil exe "norm! `[\<c-v>`]y"
        elseif a:type is# 'vis'
            sil norm! gvy
        elseif a:type is# 'Ex'
            sil exe a:2.','.a:3.'y'
        else
            return ''
        endif
        let raw_lines = split(@", "\n")

    catch
        return lg#catch_error()

    finally
        let &cb  = cb_save
        let &sel = sel_save
        call call('setreg', reg_save)
    endtry

    " We don't source the code by simply dumping it on the command-line:
    "
    "     :so @"
    "
    " It wouldn't work when the code contains continuation lines, or tabs
    " (trigger completion).
    "
    " So, instead, we dump it in a temporary file and source the latter.
    let lines     = filter(raw_lines, { i,v -> v !~# '[\u21d4\u2192\u2502\u2514\u250c]\|^[\u21a3\u21a2]' })
    let lines     = map(raw_lines, { i,v -> substitute(v, '[\u2718\u2714\u250a].*', '', '') })
    let tempfile  = tempname()
    call writefile(lines, tempfile, 'b')

    try
        " the function was invoked via the Ex command
        if a:0
            if exists(':ToggleEditingCommands') ==# 2
                ToggleEditingCommands 0
            endif

            exe a:1.'verb source '.tempfile
            "   │
            "   └─ use the verbosity level passed as an argument to `:SourceSelection`

        " the function was invoked via the mapping
        else
            exe 'source '.tempfile
        endif

    catch
        return lg#catch_error()
    finally
        if a:0 && exists(':ToggleEditingCommands') ==# 2
            ToggleEditingCommands 1
        endif
    endtry
endfu

