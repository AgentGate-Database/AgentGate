function(agentgate_set_warnings target)
  target_compile_options(${target} PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Werror)
  if(AGENTGATE_SANITIZERS)
    target_compile_options(${target} PRIVATE
      -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(${target} PRIVATE -fsanitize=address,undefined)
  endif()
endfunction()
