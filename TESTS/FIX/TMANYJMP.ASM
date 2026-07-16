; TMANYJMP.ASM -- regression fixture: more than 128 unqualified auto-sized
; JMPs in one file must still assemble (BUG B6: the old fixed
; MaxJmpDecisions=128 array made the 129th such JMP a hard "internal
; limit" error -- now a chunked list with no practical ceiling).
bits 16
cpu 8086
section .text
global Foo
Foo:
L0:
    jmp L0
L1:
    jmp L1
L2:
    jmp L2
L3:
    jmp L3
L4:
    jmp L4
L5:
    jmp L5
L6:
    jmp L6
L7:
    jmp L7
L8:
    jmp L8
L9:
    jmp L9
L10:
    jmp L10
L11:
    jmp L11
L12:
    jmp L12
L13:
    jmp L13
L14:
    jmp L14
L15:
    jmp L15
L16:
    jmp L16
L17:
    jmp L17
L18:
    jmp L18
L19:
    jmp L19
L20:
    jmp L20
L21:
    jmp L21
L22:
    jmp L22
L23:
    jmp L23
L24:
    jmp L24
L25:
    jmp L25
L26:
    jmp L26
L27:
    jmp L27
L28:
    jmp L28
L29:
    jmp L29
L30:
    jmp L30
L31:
    jmp L31
L32:
    jmp L32
L33:
    jmp L33
L34:
    jmp L34
L35:
    jmp L35
L36:
    jmp L36
L37:
    jmp L37
L38:
    jmp L38
L39:
    jmp L39
L40:
    jmp L40
L41:
    jmp L41
L42:
    jmp L42
L43:
    jmp L43
L44:
    jmp L44
L45:
    jmp L45
L46:
    jmp L46
L47:
    jmp L47
L48:
    jmp L48
L49:
    jmp L49
L50:
    jmp L50
L51:
    jmp L51
L52:
    jmp L52
L53:
    jmp L53
L54:
    jmp L54
L55:
    jmp L55
L56:
    jmp L56
L57:
    jmp L57
L58:
    jmp L58
L59:
    jmp L59
L60:
    jmp L60
L61:
    jmp L61
L62:
    jmp L62
L63:
    jmp L63
L64:
    jmp L64
L65:
    jmp L65
L66:
    jmp L66
L67:
    jmp L67
L68:
    jmp L68
L69:
    jmp L69
L70:
    jmp L70
L71:
    jmp L71
L72:
    jmp L72
L73:
    jmp L73
L74:
    jmp L74
L75:
    jmp L75
L76:
    jmp L76
L77:
    jmp L77
L78:
    jmp L78
L79:
    jmp L79
L80:
    jmp L80
L81:
    jmp L81
L82:
    jmp L82
L83:
    jmp L83
L84:
    jmp L84
L85:
    jmp L85
L86:
    jmp L86
L87:
    jmp L87
L88:
    jmp L88
L89:
    jmp L89
L90:
    jmp L90
L91:
    jmp L91
L92:
    jmp L92
L93:
    jmp L93
L94:
    jmp L94
L95:
    jmp L95
L96:
    jmp L96
L97:
    jmp L97
L98:
    jmp L98
L99:
    jmp L99
L100:
    jmp L100
L101:
    jmp L101
L102:
    jmp L102
L103:
    jmp L103
L104:
    jmp L104
L105:
    jmp L105
L106:
    jmp L106
L107:
    jmp L107
L108:
    jmp L108
L109:
    jmp L109
L110:
    jmp L110
L111:
    jmp L111
L112:
    jmp L112
L113:
    jmp L113
L114:
    jmp L114
L115:
    jmp L115
L116:
    jmp L116
L117:
    jmp L117
L118:
    jmp L118
L119:
    jmp L119
L120:
    jmp L120
L121:
    jmp L121
L122:
    jmp L122
L123:
    jmp L123
L124:
    jmp L124
L125:
    jmp L125
L126:
    jmp L126
L127:
    jmp L127
L128:
    jmp L128
L129:
    jmp L129
L130:
    jmp L130
L131:
    jmp L131
L132:
    jmp L132
L133:
    jmp L133
L134:
    jmp L134
L135:
    jmp L135
L136:
    jmp L136
L137:
    jmp L137
L138:
    jmp L138
L139:
    jmp L139
    ret
