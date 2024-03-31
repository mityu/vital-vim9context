let s:CONTEXT_VIM_SCRIPT  = 0
let s:CONTEXT_VIM9_SCRIPT = 1
let s:CONTEXT_UNKNOWN     = 2

function! s:_vital_created(module) abort
  let a:module.CONTEXT_VIM_SCRIPT = s:CONTEXT_VIM_SCRIPT
  let a:module.CONTEXT_VIM9_SCRIPT = s:CONTEXT_VIM9_SCRIPT
endfunction

function! s:get_context() abort
  return s:get_context_pos(line('.'), col('.'))
endfunction

function! s:get_context_pos(linenr, columnnr) abort
  " First, check if there're modifiers that specify script type.
  let context = s:_determine_context_by_line(a:linenr, a:columnnr)
  if context != s:CONTEXT_UNKNOWN
    return context
  endif

  " Second, check if the line is in a function/vim9script-block.
  let context = s:_determine_context_by_blocks(a:linenr, a:columnnr)
  if context != s:CONTEXT_UNKNOWN
    return context
  endif

  " Finally, check if there's :vim9script command because when the line does
  " not meet the conditions above, the line is at script level.
  let context = s:_determine_context_by_file(a:linenr)
  if context == s:CONTEXT_UNKNOWN
    echoerr '[vim9context] Internal Error: context is unknown that is must not be.'
    let context = s:CONTEXT_VIM_SCRIPT
  endif
  return context
endfunction


" s:_determine_context_by_line()
" Determine if the context of the given position is vim9script or not by
" checking command-modifiers.
function! s:_determine_context_by_line(linenr, columnnr) abort
  "        vimscript
  " unknown   |      vim9script
  "    |      |          |
  "    v      v          v
  " <-----><------><----------->
  " :legacy vim9cmd echo 'Hello'
  let components = split(s:_getline_before_column(a:linenr, a:columnnr))
  let context = s:CONTEXT_UNKNOWN
  for c in components
    if c =~# '^\<leg\%[acy]\>$'
      let context = s:CONTEXT_VIM_SCRIPT
    elseif c =~# '^\<vim9\%[cmd]\>$'
      let context = s:CONTEXT_VIM9_SCRIPT
    elseif c =~# '^\<fu\%[nction]\>!\?$'
      return s:CONTEXT_VIM_SCRIPT
    elseif c =~# '^\<def\>!\?$'
      return s:CONTEXT_VIM9_SCRIPT
    elseif c =~# '^\<\%(export\|static\)\>$'
      continue
    else
      break
    endif
  endfor
  return context
endfunction

" s:_determine_context_by_blocks()
" Determine if the context of the given position is vim9script or not by
" checking if the given position is contained in any of legacy function, def
" function, and vim9script block.
function! s:_determine_context_by_blocks(linenr, columnnr) abort
  let innermost_def = s:_find_innermost_def_function(a:linenr, a:columnnr)

  " In def function, the context is always vim9script.
  if innermost_def != 0
    return s:CONTEXT_VIM9_SCRIPT
  endif

  " In legacy function, sometimes the context can be vim9script.
  let innermost_legacy = s:_find_innermost_legacy_function(a:linenr, a:columnnr)
  let [linenr, columnnr] = [a:linenr, a:columnnr]
  while 1
    let innermost_commandblock = s:_find_innermost_braces_block(linenr, columnnr)
    if innermost_commandblock == 0 || innermost_commandblock < innermost_legacy
      " Any functions can appear in vim9script block.
      break
    elseif s:_is_vim9script_block_beginning(
          \ innermost_commandblock, col([innermost_commandblock, '$']))
      return s:CONTEXT_VIM9_SCRIPT
    elseif innermost_commandblock == 1
      " There's no outer block anymore.
      break
    endif
    let linenr = innermost_commandblock - 1
    let columnnr = col([linenr, '$'])
  endwhile

  if innermost_legacy != 0
    return s:CONTEXT_VIM_SCRIPT
  endif
  return s:CONTEXT_UNKNOWN
endfunction

" s:_is_vim9script_block_beginning()
" Check if the given position is in a vim9script block such as below:
"   <------ unknown ------> <-- vim9script -->
"   :command! GreatCommand {
"     <-- vim9script -->
"   }
"
"   <------ unknown ------> <-- vim9script -->
"   :autocmd Event pattern {
"     <-- vim9script -->
"   }
"
"   (For details, see :h :command-repl)
"
" If the given position is in a vim9script block, returns 1; otherwise,
" returns 0.
function! s:_is_vim9script_block_beginning(linenr, columnnr) abort
  let line = s:_getline_before_column(a:linenr, a:columnnr)
  let patterns = []

  " Pattern matcher for :command
  call add(patterns, '\v^\s*com%[mand]>!?%(\s+-\S+)*\s+\u\a*\s+\{\s*$')

  " Pattern matcher for :autocmd
  call add(patterns,
  \  '\v^\s*au%[tocmd]>%(\s+\S+){2,3}%(\s+%(\+\+\a+|nested)>)*\s+\{\s*$')

  for p in patterns
    if line =~# p
      return 1
    endif
  endfor
  return 0
endfunction

" s:_determine_context_by_file()
" Check if the vim9script use exists or not and determine if the file is
" vim9script file or not. This function must not return
" s:CONTEXT_UNKNOWN.
function! s:_determine_context_by_file(linenr) abort
  let curpos = getpos('.')
  try
    call cursor(1, 1)
    let linenr = search('^\s*\<vim9s\%[cript]\>\%(\s\+noclear\)\?\s*$',
          \ 'cnW', a:linenr)
    if linenr <= 0 || linenr == a:linenr
      return s:CONTEXT_VIM_SCRIPT
    endif
    return s:CONTEXT_VIM9_SCRIPT
  finally
    call setpos('.', curpos)
  endtry
endfunction

function! s:_find_innermost_legacy_function(linenr, columnnr) abort
  let begin = '\v^\s*%(<%(export|leg%[acy]|vim9%[cmd])>\s+)*fu%[nction]>'
  let end = '\<en\%[dfunction]\>'
  return s:_find_innermost_block(begin, end, a:linenr, a:columnnr)
endfunction

function! s:_find_innermost_def_function(linenr, columnnr) abort
  let begin = '\v^\s*%(<%(export|legacy|vim9cmd)>\s+)*def>'
  let end = '\<enddef\>'
  return s:_find_innermost_block(begin, end, a:linenr, a:columnnr)
endfunction

function! s:_find_innermost_braces_block(linenr, columnnr) abort
  let begin = '\s{\s*$'
  let end = '^\s*}\s*$'
  return s:_find_innermost_block(begin, end, a:linenr, a:columnnr)
endfunction

" Search the innermost block and returns the line that the block begins.
" If block is not found, returns 0.
function! s:_find_innermost_block(begin, end, linenr, columnnr) abort
  if s:_getline_before_column(a:linenr, a:columnnr) =~# a:begin
    return a:linenr
  endif

  let curpos = getpos('.')
  try
    " NOTE: The block end position is special. The context of the whole line
    " of ending block should be same to it of the block:
    "   :endfunction <-- vimscript -->
    "   :enddef <-- vim9script -->
    "   } <-- vim9script -->
    " That's why, if the line matches a:end, make the column of cursor 1 then
    " search pairs.
    if getline(a:linenr) =~# a:end
      call cursor(a:linenr, 1)
    else
      call cursor(a:linenr, a:columnnr)
    endif
    let linenr = searchpair(a:begin, '', a:end, 'bWnz')
    if linenr <= 0
      return 0
    endif
    return linenr
  finally
    call setpos('.', curpos)
  endtry
endfunction


function! s:_getline_before_column(linenr, columnnr) abort
  let line = getline(a:linenr)
  if stridx(mode(), 'i') != -1
    let line = strpart(line, 0, a:columnnr - 1)
  else
    let line = strpart(line, 0, a:columnnr)
  endif
  return line
endfunction


" For testing
function! s:_internal_contexts() abort
  return {
  \ 'vimscript':  s:CONTEXT_VIM_SCRIPT,
  \ 'vim9script': s:CONTEXT_VIM9_SCRIPT,
  \ 'unknown':     s:CONTEXT_UNKNOWN,
  \}
endfunction
