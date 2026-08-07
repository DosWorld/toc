#### GUIDE

- LANGUAGE DEFINITION
- STANDARD UNITS
- MEMORY MANAGEMENT
- ASSEMBLY LANGUAGE
#### BoRLAND

#### Pasca/®

#### Version 7.0

#### Language Guide

|BORLAND|INTERNATIONAL|INC. 1800|GREEN HILLS|ROAD|
|---|---|---|---|---|
|P.O. BOX|660001,|VALLEY, CA|95067-0001||

scons

Borland International. All rights reserved. All Borland products are trademarks or registered trademarks of Borland International, Inc. Windows, as used in this manual, shall refer to Microsoft's implementation of a windows system. Other brand and product names are trademarks or registered trademarks of their respective holders.

PRINTED IN THE USA. 9 8

#### E N T s

..

||Real|types.......................|||28|
|---|---|---|---|---|---|
||Software 80x87 String types Structured|floating floating types|point point||29 29 29 30|
|5|Array|types|||30|
|5|Record|types|||32|
|6|Object|types.....................|||33|
|8|Components||and scope||36|
|9|Methods||||37|
|10|Virtual Dynamic|methods methods|||37 38|
|10|Instantiating||objects|............|38|
|11|Method|activations|||40|
|13|Qualified-method||activations||41|
|14|Set types File types|........................|||42 42|
|15|Pointer|types||.............|43|
|15|Type|Pointer|||43|
|16|Type|PChar|||43|
|17|Procedural|types|||44|
|18|Procedural|values|................||44|
|19|Type|compatibility|...............||46|
|19|Identical|and compatible||types|46|
|20|Type|identity|....................||46|
|20|Type|compatibility|||47|
|21|Assignment The type|compatibility declaration|part||48 49|
|23 23|Chapter|5 Variables|and|typed||
|24||constants|||51|
|25|Variable|declarations|||51|
|25|The data|segment|||52|
|26|The stack|segment|||52|
|26|Absolute|variables|||53|

#### o D u c T o N

This manual is about the Turbo Pascal language. It

|User's Guide|for an overview||
|---|---|---|
|the entire|Turbo|Pascal|
|documentation|set and|how|
|to use|the Turbo|Pascal|
|manuals|most effectively.||

*of* • Presents the formal definition of the Turbo Pascal language

- Introduces the run-time library and tells you how to use the units that make it up
- Describes what goes on inside Turbo Pascal in regards to memory, data formats, calling conventions, input and output, and automatic optimizations
- Explains how to use Turbo Pascal with assembly language You'll find this manual most useful if you are an experienced Pascal programmer.
##### Read the User's Guide if

- You want to know how to install Turbo Pascal
- You've used Turbo Pascal before and you want to know what is new in this release
- You're not familiar with Borland's integrated development environment (the IDE)
- You want to know how to use the integrated debugger
- You want to refresh your knowledge about pointers
- You are new to object-oriented programming Read the *Programmer's Reference* to look up reference material on
- The run-time library
- Compiler directives
- Error messages
- The command-line compiler
- The editor
*Introduction*

##### System, Dos, WinDos, Strings, Crt,

##### Overlay, and Graph units.

Part III, "Inside Turbo Pascal," presents technical information for advanced users about

- How Turbo Pascal uses memory
- How Turbo Pascal implements program control
- Using the 80x87
- Optimizing your code Part IV, "Using Turbo Pascal with assembly language," explains how to use the built-in assembler and how to link your Turbo Pascal programs with code written in Turbo Assembler.
*Language Guide*

#### Pascal program?

|The next|several chapters|present|the formal|definition|of the|
|---|---|---|---|---|---|
|Turbo|Pascal language.|Each|discusses|an element|of|
|Turbo program.|Pascal. Together,|these|elements make|up a Turbo|Pascal|
|It's difficult|to gain|an understanding|of the|whole by|examining|
|only the|parts, however.|This|chapter presents|an overview|of a|
|Turbo|Pascal program|and omits|the details.|It gives you|a brief|
|description|of each|of the elements|of a program|and then|shows|
|you how|they all|fit together.|You can then|refer to Chapters|2|
|through|10 to find|the details|of the language.|||

chapter

#### A Turbo Pascal program

In its simplest form, a Turbo Pascal program is made up of a *program heading,* which names the program, and the *main program* *block,* which accomplishes the purpose of the program. Within the main program block is a section of code that occurs between two key words: **begin** and **end.** Here is a very simple program that concepts:

|illustrates|these|||
|---|---|---|---|
|program begin|Welcome;|||
|Writeln('Welcome end.||to Turbo|Pascal');|

*Chapter* 1, *What is* a *Turbo Pascal program?*

|The logic code putting and Procedures smaller, in occurs program discrete|code between the last begin and end in a program drives the In a very simple program, this section of of the program. might be all you need. In larger, more complex programs, all your code here can make your program harder to read understand-and more difficult to develop. and functions let you divide the logic of a program into more manageable chunks, and are similar to subroutines some other languages. All the action in a procedure or function in the code between its begin and end just like in the main block. Each of these segments of code performs a small, task.||
|---|---|---|
|Procedure|or function Procedure or function heading Procedure or function block begin !.L09iC||
||end;||

Procedure or function diagram

If you find your program does the same thing many times, you might want to put the logic into a procedure or function. You write the code in a procedure or function once and your program can use it as often as necessary.

Here is an example of a function. This *GetNumber* function gets a number from the user:

*Language Guide*

function GetNumber: Reali var Response: Reali begin Write('Enter a number: ') i

|Write('Enter|a number:|') i|
|---|---|---|
|Readln(Response)i|||
|GetNumber endi|:= Responsei||

A procedure or function must appear before the main code section in the main program block. The main code section can

||then use the|procedure|or function.|
|---|---|---|---|
|program|Pascal program|||
|diagram|Program Main program Procedures|heading block or functions|(0 or more)|
||begin Main|program logic||
||end.|||

Simple Pascal

I

I

The following example is an outline of a program that uses the *GetNumber* function. The programmer has divided the logic of this program into three tasks:

1. Get a number from the user.
2. Perform the necessary calculations with the user-supplied number.
3. Print a report. The main logic of the program is found between the last **begin** and **end.**
*Chapter* 1, *What is* a *Turbo Pascal program?*

{Assign a value}

{Activate a procedure}

{Conditional statement} Y;

**begin** {Compound statement} X := 3; Y := 4; Z : = 5; **end;**

***Language Guide***

Pascal statement to a sentence in a human language such as English, Danish, or Greek. Simple Pascal statements and simple human sentences hold one complete thought. Structured Pascal statements and complex sentences contain more complicated logic.

Just as a sentence is made up of phrases, so is a Pascal statement made up of expressions. The phrases of a sentence are made up of words, and the expressions of a statement are composed of ele- ments called factors and operators. Expressions usually compare things or perform arithmetic, logical, or Boolean operations.

Just as phrases in a human language can be made up of smaller phrases, so can expressions in Pascal be made up of simpler expressions. You can read about all the combinations of factors and operators in Chapter 6 that make up expressions. They can be quite complex. For now, it might help to see some examples of expressions:

##### x + Y

Done <> Error I <= Length -x

*Chapter* 1, *What is* a *Turbo Pascal program?*

Pascal program. They make up the factors and operators of expressions. Tokens are special symbols, reserved words, identifiers, labels, numbers, and string constants; they are akin to the words and punctuation of a written human language. These are examples of Pascal tokens:

|function|{reserved|word}||
|---|---|---|---|
||{special {special|symbol} symbol}||
|Calculate 9|{number}|for|a procedure}|

{identifier

Here is an illustration of a statement. You can see that statements are made up of expressions, which are made up of tokens.

|Statements|(1|or|more)|
|---|---|---|---|
|Expressions||(1|or more)|
|Tokens|(1|or|more)|

##### Types, variables, constants, and typed constants

A *variable* can hold a value that can change. Every variable must have a *type.* A variable's type specifies the set of values the variable can have.

For example, this program declares that variables X and Yare of type *Integer;* therefore, the only values X and Y can contain are integers, which are whole numbers. Turbo Pascal displays an error message if your program tries to assign any other type of value to these variables.

*Language Guide*

|||{Constant|A never changes|in value}||
|---|---|---|---|---|---|
|||{Typed|B gets|an|value}|
|X, Y:|Integer;|{Variables|X and|type Integer}||
|J: Real; begin||{Variable|J type|Real}||
|X := 7;||{Variable|X assigned|a value}||
|Y := 8;||{Variable|Y assigned|a value}||
|X := Y|+ Y;|{The value|of variable|X changes}||
|B := 57;||{Typed|B gets|a new value}||
|J := 0.075; end.||{Variable|J gets a|floating-point|value}|

constant initial

Yare is

is is

constant

In this simple and not very useful program, X is assigned the value 7 originally; two statements later it is assigned a new value, Y + Y. The value of a variable can vary.

*A* is a *constant.* The program gives it a value of 12 and this value can't change-its value remains constant throughout the program.

*B* is a *typed constant.* It's given a value when it's declared, but it's also given a type of *Integer.* You can think of a typed constant as a variable with an initial value. The program can later change the initial value of *B* to some other value.

The part of this program that declares the constants and variables is called the *declaration part.*

If you'll look back at the code example on page 7, you'll see that the function *GetNumber* has a declaration part that declares a variable. Procedures and functions can contain a declaration part just as a program or unit can.

#### Putting it all together

been

|Now that|you've|introduced|to the primary|components||of a|
|---|---|---|---|---|---|---|
|Turbo Pascal|program,|you need|to see how|they all|fit together.||
|Here's an|illustration|of a Turbo|Pascal program:||||

*Chapter* 7, *What is* a *Turbo Pascal program?*

|Pascal||program|||
|---|---|---|---|---|
||Program Uses Main begin end.|heading (optional) clause program block Declarations Procedures or functions (0 or more) Procedure or function heading Statements (1 or more)|||

Pascal program

The program heading, the optional **uses** clause (we'll talk about this in the next section), and the main program block make up a Pascal program. Within the main program block can exist the smaller blocks of procedures and functions. Although the diagram doesn't show this, procedures and functions can be nested within other procedures and functions. In other words, blocks can contain other blocks.

Combined with other tokens and blank spaces, tokens make up expressions which make up statements.

*Language Guide*

Pa,scal program can use blocks of code in separate modules called *units.* You can think of a unit as a mini-program your application can use. Like a program, it has a heading, called a unit heading, and a main block that contains a code section delineated by **begin** and **end.**

Any Turbo Pascal main program block can include a line that enables the program to use one or more units. For example, if you are writing a program called *Colors* and you want to change the color of the text as it appears on your screen, you can specify that your program use the standard *Crt* unit that is part of the Turbo Pascal run-time library:

program Colors; uses Crt; begin

end.

|The uses|Crt line tells Turbo|Pascal|to include|the Crt|unit in the|
|---|---|---|---|---|---|
|executable|program.|The Crt unit|contains|all the necessary|code|
|to change|the color|the text in|your program,|among|other|
|things. Simply|including|uses|Crt, your|program|can use all|
|the procedures|and|functions in|the Crt unit.|you|all the|
|code required|to create|the functionality|of|the Crt unit|within|
|your program,|it would|be a lot|more work,|and it would||
|sidetrack|you from|main purpose|of your|program.||
|Turbo Pascal's|run-time|library|includes several|units|you'll find|
|useful. For|example,|use the Dos|unit and your|program|has|
|access to|several operating|system|and file-handling|routines.||
|You can|also write your|own units.|Use them|to divide|large|
|programs|into logically|related|modules. Code|you place|in a unit|
|can be used|by any|program. You|only have|to write|the code|
|once, then|you can use|it many|times.|||

of by If put

the

*Chapter* 7, *What is* a *Turbo Pascal program?*

**diagrams**

As you read Chapters 2 through 10, which define the Turbo Pascal language, you'll encounter *syntax diagrams.* For example,

formal parameter list

To read a syntax diagram, follow the arrows. Frequently, more than one path is possible. The above diagram indicates that a formal parameter list is optional in a procedure heading. You can follow the path from the identifier to the end of the procedure heading, or you can follow it to the formal parameter list before reaching the end.

The names in boxes stand for constructions. Those in circles- reserved words, operators, and punctuation-are the actual terms used in the program; they are boldfaced in the diagrams.

*Language Guide*

##### A p T E R

#### Tokens

*Tokens* are the smallest meaningful units of text in a Pascal program. They are categorized as special symbols, identifiers, labels, numbers, and string constants.

A Pascal program is made up of tokens and *separators.* A separator is either a blank or a comment. Two adjacent tokens must be separated by one or more separators if each token is a reserved word, an identifier, a label, or a number.

##### Special symbols

Turbo Pascal uses the following subsets of the ASCII character set:

- **Letters-the** English alphabet, *A* through Z and *a* through z
- **Digits-the** Arabic numerals a through 9
- **Hex digits-the** Arabic numerals a through 9, the letters *A* through *F,* and the letters *a* through *f*
- **Blanks-the** space character (ASCII 32) and all ASCII control characters (ASCII a through 31), including the end-of-line or return character (ASCII 13) These are the syntax diagrams for letter, digit, and hex digit:
*Chapter* 2, *Tokens*

#### -----.-----, ¢... ~

Ihexdigit 4 digiti

##### A··· F ...cp

$ • Special symbols are characters that have one or more fixed meanings.

The following single characters are special symbols:

+ _ * / = < > [] ., () :; 'A @ { } $#

These character pairs are also special symbols:

<= >= := .. (* *) (. .)

A left bracket ([) is equivalent to the character pair of left parenthesis and a period-(., and a right bracket (]) is equivalent to the character pair of a period and a right parenthesis-.). Likewise, a left brace ({) is equivalent to the character pair of left parenthesis and an asterisk-(*, and a right brace 0) is equivalent to the character pair of an asterisk and a right parenthesis-*).

#### Reserved words and standard directives

*Reserved words can'f* be Reserved words appear in boldface throughout this manual. *redefined.* Turbo Pascal is *not* case sensitive, however, so you can use either uppercase or lowercase letters in your programs.

##### Following are Turbo Pascal's reserved words:

Table 2.1

Turbo Pascal reserved words and file not then array for object to asm function of type begin goto or unit case if packed until const implementation procedure uses constructor in program var destructor inherited record while div inline repeat with do interface set xor downto label shl else mod shr end nil string

*Language Guide*

The following are Turbo Pascal's standard (built-in) directives. Directives are used only in contexts where user-defined identifiers can't occur. Unlike reserved words, you can redefine standard but

||directives,|we advise that you|don't.|
|---|---|---|---|
|Turbo Pascal directives|absolute assembler external private|far forward interrupt|near private public|

2,2 **absolute far near virtual** Turbo Pascal directives

and **public** act as reserved words within object type declarations, but are otherwise treated as directives.

#### Identifiers

Identifiers denote constants, types, variables, procedures, functions, units, programs, and fields in records.

An identifier can be of any length, but only the first 63 characters are significant. An identifier must begin with a letter or an under- score character U and can't contain spaces. Letters, digits, and underscore characters (ASCII $5F) are allowed after the first char- acter. Like reserved words, identifiers are *not* case sensitive.

|Units|are described|in|
|---|---|---|
|Chapter 5|the User's|Guide|
|and Chapter|10 this|book.|

When several instances of the same identifier exist, you may need *of* to qualify the identifier by another identifier to select a specific *of* instance. For example, to qualify the identifier *ldent* by the unit identifier *UnitName,* write *UnitName.Ident.* The combined identifier is called a *qualified identifier.*

identifier

underscore-G-

qualified ~d t'f' identifier ~

*Chapter* 2, *Tokens*

10- 2;

12.25e+6 or 12.25e6 both

|||6.|
|---|---|---|
|hex digit|sequence||
|digit|||
|unsigned|integer||

##### mean 12.25 x 10+

6 Syntax diagrams for writing numbers follow:

#### -rl. hex digit tT--

sequence~

#### Signw

|unsigned|real|||||
|---|---|---|---|---|---|
|digit|sequence||digit sequence||scale factor|
|scale|factor|e|.|digit sequence||
|unsigned|number|unsigned unsigned|integer real|||
|signed|number||unsigned|number||
|||sign||||

##### 11--;:::========:::;-,+

### ~ Lr;i5t II ~ ~

#### L@ I f--

*Language Guide*

Other decimal numbers denote integer-type constants; they must be within the range-2,147,483,648 to 2,147,483,647.

Hexadecimal numbers denote integer-type constants; they must be within the range $00000000 to $FFFFFFFF. The resulting value's sign is implied by the hexadecimal notation.

A label is a digit sequence in the range 0 to 9999. Leading zeros are not significant. Labels are used with **goto** statements.

label

As an extension to Standard Pascal, Turbo Pascal also allows identifiers to function as labels.

#### Character strings

A character string is a sequence of zero or more characters from the extended ASCII character set, written on one line in the program and enclosed by apostrophes. A character string with nothing between the apostrophes is a *null string.* Two sequential apostrophes within a character string denote a single character, an apostrophe. For example,

'TURBO' { TURBO } 'You"ll see' { You'll see} {, } { null string } { a space }

As an extension to Standard Pascal, Turbo Pascal lets you embed control characters in character strings. The # character followed by an unsigned integer constant in the range 0 to 255 denotes a character of the corresponding ASCII value. There must be no separators between the # character and the integer constant. Likewise, if several control characters are part of a character string, there must be no separators between them. For example,

*Chapter* 2, *Tokens*

|#13#10|||
|---|---|---|
|'Line|l'#13'Line2'||
|#7#7'Wake|up!'#7#7||
|character|string|quoted string control string|
|quoted string||string character|
|string character|||

#### -() 10-- q P

control string-r0=l unsigned integer t-T-

|A character|string's|length is the|actual number|of characters||in the|
|---|---|---|---|---|---|---|
|string. A|character|string of any|length is|compatible|with any||
|string type,|and with|the PChar|type when|the extended|syntax|is|
|enabled|{$X+}. Also,|a character|string of|length one|is compatible||
|with any|Char type,|and a character|string|of length|N, where|N is|
|greater|than or equal|to one, is|compatible|with packed|arrays|of|

##### N characters.

The following constructs are comments and are ignored by the compiler:

|{Any text|not containing|right brace|}|
|---|---|---|---|
|(* Any text|not containing||parenthesis|
||||($)|

star/right *)

A comment that contains a dollar sign immediately after the opening { or (* is a *compiler directive.* A mnemonic of the compiler command follows the $ character.

**lines**

Turbo Pascal program lines have a maximum length of 126 characters.

*Language Guide*

##### A p T E R

#### Constants

A *constant declaration* declares a constant within the block containing the declaration. A constant is an identifier that holds a value that can't change. A constant identifier can't be included in its own declaration.

constant declaration rl identifier ~ constant ~0-r

*Pascal*As an extension to Standard Pascal, Turbo Pascal allows the use of *allows only* a *simple con-* *constant expressions.* A constant expression is an expression that *stant, Turbo Pascal allows* a *constant expression.*can be evaluated by the compiler without actually executing the program. Examples of constant expressions follow:

100 'A' 256-1 (2.5 + 1) (2.5-1) 'Turbo' + ', + 'Pascal' Chr (32) Ord (, Z ')-Ord (, A') + 1

The simplest case of a constant expression is a simple constant, such as 100 or *J* A'.

constant-l expression f--

Because the compiler has to be able to completely evaluate a constant expression at compile time, the following constructs are *not* allowed in constant expressions:

*Chapter* 3, *Constants*

- References to variables and typed constants (except in constant address expressions as described on page 59)
- Function calls (except those noted in the following text)
- The address operator (@) (except in constant address expressions as described on page 59) Except for these restrictions, constant expressions follow the same
6, *"Expressions."* syntactical rules as ordinary expressions.

The following standard functions are allowed in constant expressions:

##### Abs High Low Pred SizeD!

##### Chr Length Odd Ptr Succ

##### Hi La Ord Round Swap

*Trunc*

Here are some examples of the use of constant expressions in constant declarations:

const Min = 0; Max = 100; Center = (Max-Min) div 2;

|Center|(Max-Min)|div 2;||
|---|---|---|---|
|Beta Chr(225);||||
|NumChars|Ord('Z')|-Ord('A')|+ 1;|
|Message|'Out of memory'|;||
|ErrStr|Error: '|+ Message|+|
|ErrPos Ln10 = 2.302585092994045684; Ln10R|80-Length 1 / Ln10;|(ErrStr)|div 2;|
|Numeric|0' ' 9'|1;||
|Alpha|A' ' Z',|, a' ' z' 1|;|
|AlphaNum|Alpha +|Numeric;||

= = = = ' '. '; =

= = [' .. = [' .. .. =

*Language Guide*

##### A p T E R

#### Types

When you declare a variable, you must state its *type.* A variable's type circumscribes the set of values it can have and the operations that can be performed on it. A *type declaration* specifies the identifier that denotes a type.

type declaration-I identifier ~~

When an identifier occurs on the left side of a type declaration, it's declared as a *type identifier* for the block in which the type declaration occurs. A type identifier's scope doesn't include itself except for pointer types.

type

type identifier

There are five major type classes. They are described in the following sections..

##### Simple types

Simple types define ordered sets of values.

*Chapter* 4, *Types*

simple type

real type-I real type identifier f- A real-type identifier is one of the standard identifiers: *Real,* *Single, Double, Extended,* or *Compo*

##### Ordinal types

|Ordinal types|are a subset|of simple|types.|All simple|types other||
|---|---|---|---|---|---|---|
|than real types characteristics:|are ordinal|types,|which are|set off|six||
|• All possible|values of|a given ordinal|type|are ordered|set,||
|and each|possible value|is associated|with|ordinality,|which|is|
|integral|value. Except|for integer-type||values, the|first value||
|of every|ordinal type|has ordinality|0, the|next has ordinality||I,|
|and so on|for each value|in that|ordinal type.|The ordinality||of|
|integer-type|value|is the value|itself. In|any ordinal|type,||
|each value|other than|the first has|a predecessor,|and|each value||
|other than type.|the last has|a successor|based|on the ordering|of|the|
|• The standard|function|Ord can|be applied|to any ordinal-type|||
|value to|return the ordinality|of|the value.||||
|• The standard|function|Pred can|be applied|to any ordinal-type|||
|value to|return the predecessor||of the value.|applied|to the||
|first value|in the ordinal|type and|if range-checking||is enabled||
|{$R+}, Pred|produces|a run-time|error.||||
|• The standard|function|Suee can|be applied|to any ordinal-type|||
|value to|return the successor|of|the value.|applied|to the last||
|value in Suee produces|the ordinal a run-time|and if error.|range checking|is enabled|{$R+},||
|• The standard|function|Low can|be applied|to an ordinal-type|||
|and to a|variable reference|of an|ordinal|type. The result|is the||
|lowest value|in the range|of the|given ordinal|type.|||
|• The standard|function|High can|be applied|to ordinal-type|||
|and to a|variable reference|of an|ordinal|type. The result|is the||
|highest The syntax|in the of an ordinal|range of the type follows:|given ordinal|type.|||

by

an an an

an

If

If type

an

value

*Language Guide*

type 1 subrange type enumerated type ordinal type identifier

Turbo Pascal has ten predefined ordinal types: *Integer, Shortint,* *Longint, Byte, Word, Boolean, ByteBool, WordBool, LongBool,* and *Char.* In addition, there are two other classes of user-defined ordinal types: enumerated types and subrange types.

Integer types There are five predefined integer types: *Shortint, Integer, Longint,* *Byte,* and *Word.* Each type denotes a specific subset of the whole numbers, according to the following table:

Table 4.1

|Type|Range|Format|
|---|---|---|
|Shortint|-128 .. 127|Signed 8-bit|
|Integer|-32768 .. 32767|Signed 16-bit|
|Longint|-2147483648 .. 2147483647|Signed 32-bit|
|Byte|0 .. 255|Unsigned 8-bit|
|Word|0 .. 65535|Unsigned 16-bit|

Predefined integer types

Arithmetic operations with integer-type operands use 8-bit, 16-bit, or 32-bit precision, according to the following rules:

- The type of an integer constant is the predefined integer type with the smallest range that includes the value of the integer constant.
- For a binary operator (an operator that takes two operands), both operands are converted to their common type before the operation. The common type is the predefined integer type with the smallest range that includes all possible values of both types. For example, the common type of *Integer* and *Byte* is *Integer,* and the common type of *Integer* and *Word* is *Longint.* The operation is performed using the precision of the common type, and the result type is the common type.
- The expression on the right of an assignment statement is evaluated independently from the size or type of the variable on the left.
- Any byte-sized operand is converted to an intermediate word- sized operand that is compatible with both *Integer* and *Word* before any arithmetic operation is performed.
*Typecasting is described in*An integer-type value can be explicitly converted to another *Chapters and 6.* integer type through typecasting.

*Chapter* 4, *Types*

- *False* < *True*
- *Ord(False)* = a
- *Ord(True)* = 1 *.Succ(False)* = *True*
- *Pred(True)* = *False* *Boolean* and *ByteBool* variables occupy one byte, a *WordBool* variable occupies two bytes (one word), and a *LongBool* variable occupies four bytes (two words). *Boolean* is the preferred type and uses the least memory; *ByteBool, WordBool,* and *LongBool* exist primarily to provide compatibility with other languages and the Windows environment. A *Boolean* variable can assume the ordinal values a and 1 only, but variables of type *ByteBool, WordBool,* and *LongBool* can assume other ordinal values. An expression of type *ByteBool, WordBool,* or *LongBool* is considered *False* when its ordinal value is zero, and *True* when its ordinal value is nonzero. Whenever a *ByteBool,* *WordBool,* or *LongBool* value is used in a context where a *Boolean* value is expected, the compiler will automatically generate code that converts any nonzero value to the value *True.*
Char type *Char's* set of values are characters, ordered according to the extended's ASCII character set. The function call *Ord(Ch),* where *Ch* is a *Char* value, returns *Ch's* ordinality.

A string constant of length 1 can denote a constant character value. Any character value can be generated with the standard function *Chr.*

Enumerated types Enumerated types define ordered sets of values by enumerating the identifiers that denote these values. Their ordering follows the sequence the identifiers are enumerated in.

enumerated type-CD--I identifier list ~

identifier list ~

*Language Guide*

Suit = (Club, Diamond, Heart, Spade);

Given these declarations, *Diamond* is a constant of type *Suit.*

When the *Ord* function is applied to an enumerated type's value, *Ord* returns an integer that shows where the value falls with respect to the other values of the enumerated type. Given the preceding declarations, *Ord(Club)* returns zero, *Ord(Diamond)* returns I, and so on.

Subrange types A sub range type is a range of values from an ordinal type called the *host type.* The definition of a subrange type specifies the smallest and the largest value in the subrange; its syntax follows:

subrange type-I constant ~o-I constant ~

Both constants must be of the same ordinal type. Sub range types of the form *A .. B* require that *A* is less than or equal to B.

##### These are examples of subrange types:

##### o .. 99

-128 .. 127 Club .. Heart

A variable of a sub range type has all the properties of variables of the host type, but its run-time value must be in the specified interval.

One syntactic ambiguity ar~ses from allowing constant expres- sions where Standard Pascal only allows simple constants. Consider the following declarations:

*Chapter* 4, *Types*

const X = 50; Y = 10; type Color = (Red, Green, Blue);

|Color|(Red, Green,|Blue);||
|---|---|---|---|
|Scale|(X-Y)|2 (X + Y)|2;|

##### = * .. *

Standard Pascal syntax dictates that, if a type definition starts with a parenthesis, it's an enumerated type, such as the *Color* type in the previous example. The intent of the declaration of *scale* is to define a subrange type, however. The solution is to reorganize the first subrange expression so that it doesn't start with a parenthesis, or to set another constant equal to the value of the expression and use that constant in the type definition:

type Scale = 2 * (X-Y) .. (X + Y) * 2;

**types**

A real type has a set of values that is a subset of real numbers, which can be represented in floating-point notation with a fixed number of digits. A value's floating-point notation normally comprises three values-M, B, and E-such that M x BE = N, where B is always 2, and both M and E are integral values within the real type's range. These M and E values further prescribe the real type's range and precision.

There are five kinds of real types: *Real, Single, Double, Extended,* and *Camp.* The real types differ in the range and precision of values they hold as shown in the following table:

||Real data Table|types 4.2|||||Significant|Size in|
|---|---|---|---|---|---|---|---|---|
||||Type|Range|||digits|bytes|
|The Comp|type holds|only||2.9 X 10-39|.. 1.7 X|10 38|11-12|6|
|integral|values 7 to 7,|within which is||1.5 X 10-45 5.0 X 10-324|.. 3.4 X .. 1.7 X|10 38 10 308|7-8 15-16|4|
|approximately-9.2x||7078to||3.4 X 10-4932|.. 1.1 X|10 4932|19-20|10|
||9.2x|7078 •|Camp|63|63||19-20|8|

*Real* *Single* _2'3+ 2'3-*Double* 8 *Extended* _2 + 1 .. 2-1

Turbo Pascal supports two models of code generation for performing real-type operations: *software* floating point and *80x87* floating point. Use the **$N** compiler directive to select the appropriate model. If no 80x87 is present, enable the **$E** compiler directive to provide full 80x87 emulation in software.

*Language Guide*

In the {$N-} state, which is selected by default, the generated code performs all real-type calculations in software by calling run-time library routines. For reasons of speed and code size, only opera- tions on variables of type *Real* are allowed in this state. Any attempt to compile statements that operate on the *Single, Double,* *Extended,* and *Camp* types generates an error.

80x8? floating point In the {$N+} state, the generated code performs all real-type calculations using 80x87 instructions and can use all five real types.

*For more details on 80x87*Turbo Pascal includes a run-time library that will automatically *floating-point code* *emulate* an 80x87 in software if one isn't present. The **$E** compiler *generation and software* *emulation, refer to*directive is used to determine whether or not the 80x87 emulator *Chapter* 74, *"Using the* should be included in a program. *80x87."*

#### String types

|Operators for|the string|types||
|---|---|---|---|
|are described|in the sections|||
|"String|operator"|and||
|"Relational String-type procedures|operators" Chapter standard and functions|in 6.||
|are described procedures|in and functions" on page|"String string 737.|type|

A string-type value is a sequence of characters with a dynamic length attribute (depending on the actual character count during program execution) and a constant size attribute from Ito 255. A string type declared without a size attribute is given the default size attribute 255. The length attribute's current value is returned by the standard function *Length.*

-c3I--T---:::;:::---;::::==========:::;--;::::-r-

#### l-CD--I unsigned integer ~

The ordering between any two string values is set by the ordering relationship of the character values in corresponding positions. In two strings of unequal length, each character in the longer string without a corresponding character in the shorter string takes on a higher or greater-than value; for example, 'xs' is greater than 'x'. Null strings can be equal only to other null strings, and they hold the least string values.

Characters in a string can be accessed as components of an array. See the section" Arrays, strings, and indexes" on page 55.

The *Low* and *High* standard functions can be applied to a string- type identifier and to a variable reference of a string type. In this case, *Low* returns zero, and *High* returns the size attribute (maximum length) of the given string.

*Chapter* 4, *Types*

A variable parameter declared using the *OpenString* identifier, or using the **string** keyword in the {$P+} state, is an *open string* *parameter.* Open string parameters allow string variables of varying sizes to be passed to the same procedure or function.

A structured type, characterized by its structuring method and by its component type(s), holds more than one value. If a component *Pascal is 65,520 bytes.* type is struCtured, the resulting structured type has more than one level of structuring. A structured type can have unlimited levels of structuring.

structured type-or---=~---'r--or--~ ~=======::::.--,

In Standard Pascal, the word **packed** in a structured type's declaration tells the compiler to compress data storage, even at the cost of diminished access to a component of a variable of this type. In Turbo Pascal, however, **packed** has no effect; instead packing occurs automatically whenever possible.

##### Array types

Arrays have a fixed number of components of one type-the *component type.* In the following syntax diagram, the component type follows the word **of.**

index type-I ordinal type r

The index types, one for each dimension of the array, specify the number of elements. Valid index types are all ordinal types except *Longint* and 5ubranges of *Longint.* The array can be indexed in each dimension by all values of the corresponding index type;

*Language Guide*

therefore, the number of elements is the product of the number of values in each index type.

The following is an example of an array type:

array[1 .. 100] of Real

If an array type's component type is also an array, you can treat the result as an array of arrays or as a single multidimensional array. For example

array [Boolean] of array[l .. 10] of array[Size] of Real

is interpreted the same way by the compiler as

array [Boolean, 1 .. 10,Size] of Real

##### You can also express

packed array[l .. 10] of packed array[1 .. 8] of Boolean

as

packed array[l .. ..

||||10,1 8]|of Boolean|
|---|---|---|---|---|
|"Arrays,|strings,|and|||
|indexes"|on page|55.|||

You access an array's components by supplying the array's identifier with one or more indexes in brackets.

When applied to an array-type identifier or a variable reference of an array type, the *Low* and *High* standard functions return the low and high bounds of the index type of the array.

type

|||An array|of the form|
|---|---|---|---|
|||packed|N] of Char|
|See "Identical|and|||
|compatible|types" on page 46.|packed||

array[M ..

where M is less than N is called a *packed string type* (the word can be omitted because it has no effect in Turbo Pascal). A packed string type has certain properties not shared by other array types, as explained below.

##### An array type of the form

array[O .. X] of Char

where X is a positive nonzero integer is called a *zero-based* *character array.* Zero-based character arrays are used to store *null-* *terminated strings,* and when the extended syntax is enabled (using a **{$X+}** compiler directive), a zero-based character array is compatible with a *PChar* value. For a complete discussion of this topic, read Chapter 16, "Using null~terminated strings," beginning on page 167.

*Chapter* 4, *Types*

Open array parameters allow arrays of varying sizes to be passed to the same procedure or function.

A record type comprises a set number of components, or fields, that can be of different types. The record-type declaration speci-

|fies|the type|the identifier|
|---|---|---|
|record|type|field list|
|field|list -f::-"ix-ed-:--p-art-'|variant|
|fixed|part||

of each field and that names the field.

~-1--;:======:::;1~'~

#### Lj ~ L'I L:G)OOT=l part po c::o==t I ---c identifier list ~

The fixed part of a record type sets out the list of fixed fields, giving an identifier and a type for each. Each field contains information that is always retrieved in the same way.

The following is an example of a record type:

type TDateRec = record Year: Integer; Month: 1. .12; Day: 1..31; end;

The variant part shown in the syntax diagram of a record-type declaration distributes memory space for more than one list of fields, so the information can be accessed in more ways than one. Each list of fields is a *variant.* The variants overlay the same space in memory, and all fields of all variants can be accessed at all times.

##### r,---;::======:;-:::::t-J tag field type

tag field type-I ordinal type identifier 1-

*Language Guide*

variant~ ",---------," ~Idlist!I CD-

You can see from the diagram that each variant is identified by at least one constant. All constants must be distinct and of an ordinal type compatible with the tag field type. Variant and fixed fields are accessed the same way.

An optional identifier, the *tag field identifier,* can be placed in the variant part. If a tag field identifier is present, it becomes the iden- tifier of an additional fixed field-the tag field-of the record. The program can use the tag field's value to show which variant is active at a given time. Without a tag field, the program selects a variant by another criterion.

##### Some record types with variants follow:

type TPerson = record

|TPerson|record|||
|---|---|---|---|
|FirstName,|LastNarne:|string[40];||
|BirthDate:|TDate;|||
|case Citizen:|Boolean|of||
|True:|(BirthPlace:|string[40]);||
|False:|(Country:|string[201;||
|EntryPort:|string[20];|||
|EntryDate:|TDate;|||
|ExitDate: end;|TDate);|||
|TPolygon X, Y: Real;|record|||
|case Kind:|Figure|of||
|TRectangle:|(Height,|Width:|Real);|
|TTriangle:|(Sidel,|Side2,|Angle: Real);|
|TCircle: end;|(Radius:|Real);||

=

**types**

An object type"is a structure consisting of a fixed number of com- ponents. Each component is either a *field,* which contains data of a particular type, or a *method,* which performs an operation on the object. Similar to a variable declaration, the declaration of a field specifies the field's data type and an identifier that names the field. Similar to a procedure or function declaration, the decla- ration of a method specifies a procedure, function, constructor, or destructor heading.

*Chapter* 4, *Types*

#### -cD--! object type identifier ~

component list-r---;==========~~rl-;::::======~""

#### Lj object field list ~ Lj method list ~

object field list ~'--i-d-en-t-ifi-er-lis-t-~ type t-:O-r

method list method heading I-y---------------~

integer constant

method heading procedure heading **I---r-** function heading constructor heading destructor heading

component section }--~+I component list

The following code shows examples of object-type declarations:

type TPoint = object

|TPoint|object|||
|---|---|---|---|
|X, Y: end;|Integer;|||
|TRectangle|object|||
|A, B:|TPoint;|||
|procedure|Init(XA,|YA, XB,|YB: Integer);|
|procedure|Copy(var|R: TRectangle);||
|procedure|Move(DX,|DY: Integer);||

=

*Language Guide*

=

|PString|AString;||||
|---|---|---|---|---|
|PField|ATField;||||
|TField private|object||||
|Y,|Len: Integer;||||
|Name: public|String;||||
|constructor|Copy(var|F: TField);|||
|constructor|Init(FX,|FY,|FLen: Integer;|FName:|
|destructor|Done;|virtual;|||
|procedure|Display;|virtual;|||
|procedure|Edit;|virtual;|||
|function|GetStr:|String;|virtual;||
|function private|PutStr(S:|String):|Boolean;|virtual;|
|procedure end;|DisplayStr(X,|Y:|Integer;|S: String);|
|PStrField|ATStrField;||||
|TStrField private|object|(TField)|||
|Value: public|PString;||||
|constructor|Init(FX,|FY,|FLen: Integer;|FName:|
|destructor|Done;|virtual;|||
|function|GetStr:|String;|virtual;||
|function|PutStr(S:|String):|Boolean;|virtual;|
|function|Get: String;||||
|procedure end;|Put(S:|String);|||
|PNumField|ATNumField;||||
|TNumField private|object|(TField)|||
|Value, public|Min, Max:|Longint;|||
|constructor|Init(FX,|FY,|FLen: Integer;|FName:|
|FMin,|FMax: Longint);||||
|function|GetStr:|String;|virtual;||
|function|PutStr(S:|String):|Boolean;|virtual;|
|function|Get: Longint;||||

x,

String);

String);

String;

virtual;

||GetStr:|String;|
|---|---|---|
|function end;|PutStr(S:|String):|

Boolean; virtual;

Contrary to other types, an object type can be declared only in a type declaration part in the outermost scope of a program or unit. Therefore, an object type can't be declared in a variable decla- ration part or within a procedure, function, or method block.

The component type of a file type can't be an object type, or any structured type with an object-type component.

The scope of a component identifier extends over the domain of its object type. Also, the scope of a component identifier extends over procedure, function, constructor, and destructor blocks that implement methods of the object type and its descendants. For this reason, the spelling of a component identifier must be unique within an object type and all its descendants and all its methods.

Component identifiers declared in the component list that immediately follows the object-type heading and component identifiers declared in **public** component sections have no special restrictions on their scope. In contrast, the scope of component identifiers declared in **private** component sections is restricted to the module (program or unit) that contains the object-type declaration. In other words, **private** component identifiers act like normal public component identifiers within the module that contains the object-type declaration, but outside the module, any **private** component identifiers are unknown and inaccessible. By placing related object types in the same module, these object types can gain access to each other's **private** components without making the **private** components known to other modules.

Within an object-type declaration, a method heading can specify parameters of the object type being declared, even though the declaration isn't yet complete. In the previous example on page 34, the *Copy, Intersect,* and *Union* methods of the *TRee tangle* type illustrate this.

*Language Guide*

qualified method identifier

#### Y object type identifier K)--/ method identifier ~

Virtual methods By default, methods are *static.* With the exception of constructor methods, they can be made *virtual* by including a **virtual** directive in the method declaration. The compiler resolves calls to static methods at compile time. Calls to virtual methods are resolved at run time; this isknown as *late binding.*

If an object type declares or inherits any virtual methods, then variables of that type must be *initialized* through a constructor call before any call to a virtual method. Therefore, any object type that declares or inherits any virtual methods must also declare or inherit at least one constructor method.

An object type can *override* (redefine) any of the methods it inherits from its ancestors. If a method declaration in a descen- dant specifies the same method identifier as a method declaration in an ancestor, then the declaration in the descendant overrides the declaration in the ancestor. The scope of an override method extends over the domain of the descendant in which it's intro- duced, or until the method identifier is again overridden.

An override of a static method is free to change the method heading any way it pleases. In contrast, an override of a virtual method must match exactly the order, types, and names of the parameters, and the type of the function result, if any. The override must again include a **virtual** directive.

*Chapter* 4, *Types*

Pascal supports an additional class of late-bound methods called *dynamic methods.* Dynamic methods differ from virtual methods only in the way dynamic method calls are d!spatched at run time. For all other purposes, a dynamic method can be considered equivalent to a virtual method.

The declaration of a dynamic method is like that of a virtual method except that a dynamic method declaration must include a *dynamic method index* right after the **virtual** keyword. The dynamic method index must be an integer constant in the range 1..65535 and it must be unique among the dynamic method indexes of any other dynamic methods contained in the object type or its ancestors. For example,

procedure FileOpen(var Msg: TMessage); virtual 100;

An override of a dynamic method must match the order, types, and names of the parameters and the type of the function result of the ancestral method exactly. The override must also include a **virtual** directive followed by the same dynamic method index as was specified in the ancestor object type.

Instantiating objects An object is *instantiated,* or created, through the declaration of a variable or typed constant of an object type, or by applying the *New* procedure to a pointer variable of an object type. The resulting object is called an *instance* of the object type. For example, given these variable declarations,

var F: TField; Z: TZipField; FP: PField; ZP: PZipField;

|F is instance|of TFieId|and Z|is an instance|of TZipFieId.||
|---|---|---|---|---|---|
|Likewise,|after applying|New to|FP and ZP,|FP points|to an|
|instance|of TField and|ZP points|to instance|of TZipFieId.||
|an object|type contains|virtual|methods,|then instances|of that|
|object type|must be|initialized through|a constructor||call before|
|any call|to a virtual|Here's|an example:|||

an

an

If

method.

var s: TStrField; begin

S.Init(l, 1,25, 'Firstname');
*Language Guide*

S. Put ( 'Frank' );
S.Display;
S.Done;
end;

If *S.Init* had not been called, then the call to *S.Display* causes this example to fail.

Assignment to an instance of an object type doesn't initialize the instance.

An object is initialized by compiler-generated code that executes between the time that the constructor call takes place and when execution actually reaches the first statement of the constructor's code block.

If an object instance isn't initialized and range checking is 'on **{$R+},** the first call to a virtual method of the object instance results in a run-time error. If range checking is off **{$R-},** calling a virtual method of an uninitialized object instance results in undefined behavior.

The rule of required initialization also applies to instances that are components of structured types. For example,

var Comment: array[l .. 5] of TStrField;

|Comment:|5]|of TStrField;|||
|---|---|---|---|---|
|I: Integer;|||||
|begin|||||
|for I :=|1 to 5 do Comment|[I]|I + 10,|40, 'Comment');|
|for I := end;|1 to 5 do Comment|[I] .Done;|||

.Init(l,

For dynamic instances, initialization is typically coupled with allocation, and cleanup is typically coupled with deallocation, using the extended syntax of the *New* and *Dispose* procedures. Here's an example:

var SP: PStrField; begin

|begin|||
|---|---|---|
|New(SP,|1, 25,|'Firstnarne'));|
|SPA.Put('Frank')|;||
|SpA.Display;|||
|Dispose(SP,|Done);||
|end;|||

Init(l,

4, *Types*

##### PZipField can be assigned to

pointers of type *PZipField, PNumField,* and *PField,* and during execution of a program, a pointer of type *PField* might be either **nil** or point to an instance of *TField, TStrField, TNumField,* or *TZipField,* or any other instance of a descendant of *TField.*

Pointer assignment-compatibility rules also apply to object-type variable parameters. For example, the *TField.Copy* method might be passed an instance of *TField, TStrField, TNumField, TZipField,* or any other instance of a descendant of *TField.*

Method activations A method is activated through a function call or procedure statement consisting of a *method designator* followed by an actual This type of call is known as a *method activation.*

||||parameter|list.|
|---|---|---|---|---|
|See "Function|calls" on 76 and "Procedure|page|method|designator|
|statements"|on page|82.|I.....-r;============:;--:::~n method|variable|

identifier reference

The variable reference specified in a method designator must denote an instance of an object type, and the method identifier must denote a method of that object type.

The instance denoted by a method designator becomes an implicit actual parameter of the method; it corresponds to a formal variable parameter named *Self* that possesses the object type corresponding to the activated method.

For static methods, the *declared* (compile-time) type of the instance determines which method to activate. For example, the designators *F.lnit* and *FpA.Init* will always activate *TField.lnit*. because the declared type of F and FPA is *TField.*

For virtual methods, the *actual* (run-time) type of the instance governs the selection. For example, the designator FPA. *Display* might activate *TField.Display, TStrField.Display, TNumField.Display,* or *TZipField.Display,* depending on the actual type of the instance pointed to by *FP.*

|See "With|statements"|on|
|---|---|---|
|page|90 and "Method||
|declarations"|on page|703.|

Within a **with** statement that references an instance of an object type, the variable-reference part of a method designator can be omitted. In that case, the implicit *Self* parameter of the method

*Language Guide*

*Self* parameter of the method activation becomes the *Self* of the method containing the call.

Qualified-method Within a method, a function call or procedure statement allows a activations *qualified-method designator* to denote activation of a specific is known as a *qualified-method activation.*

||||method.|This type|of call|
|---|---|---|---|---|---|
|See "Function|calls" on 76 and "Procedure|page|qualified|method|designator|
|statements"|on page|82.||object type|identifier inherited|

method identifier

The object type specified in a qualified-method designator must be the same as the enclosing method's object type or an ancestor of it.

The reserved word **inherited** can be used to denote the ancestor of the enclosing method's object type; **inherited** can't be used within methods of an object type that has no ancestor.

The implicit *Self* parameter of a qualified-method activation becomes the *Self* of the method containing the call. A qualified- method activation never employs the virtual method dispatch mechanism-the call is always static and always invokes the specified method.

A qualified-method activation is generally used within an override method to activate the overridden method. Referring to the types declared earlier on page 34, here are some examples of qualified-method activations:

|constructor|TNumField.Init(FX,||FY, FLen:|Integer;|
|---|---|---|---|---|
|FName: begin|String;|FMax: Longint);|||
|inherited|Init(FX,|FY, FLen,|FName);||
|Value|:= 0;||||
|Min|:= FMin;||||
|Max end;|:= FMax;||||
|function begin|TZipField.PutStr(S:||String):|Boolean;|
|PutStr end;|(Length(S)|5) and|TNumField.PutStr(S);||

FMin,

.-=

*Chapter* 4, *Types*

As these examples demonstrate, a qualified-method activation allows an override method to "reuse" the code of the method it overrides.

**types**

A set type's range of values is the power set of a particular ordinal type (the base type). The power set is the set of all possible subsets of values of the base type including the empty set. Therefore, each possible value of a set type is a subset of the possible values of the base type.

A variable of a set type can hold from none to all the values of the set.

set type-@--@--l ordinal type ~

|Set-type|operators|are||
|---|---|---|---|
|described|in the section|"Set||
|operators"|in Chapter|6. "Set||
|constructors"|in the|same||
|chapter|shows|how to||
|construct|set|values.||

The base type must not have more than 256 possible values, and the ordinal values of the upper and lower bounds of the base type must be within the range 0 to 255.

Every set type can hold the value [], which is called the *empty set.*

##### File types

A file type consists of a linear sequence of components of the component type, which can be of any type except a file type, any structured type with a file-type component, or an object type. The number of components isn't set by the file-type declaration.

file type

If the word **of** and the component type are omitted, the type denotes an untyped file. Untyped files are low-level I/O (input/output) channels primarily used for direct access to any disk file regardless of its internal format.

The standard file type *Text* signifies a file containing characters organized into lines. Text files use special I/O procedures, which are discussed in Chapter 13, "Input and output."

*Language Guide*

A pointer type defines a set of values that point to dynamic variables of a specified type called the *base type.* A pointer-type of a dynamic variable.

|variable contains|memory the|address|
|---|---|---|
|pointer type base type|base type identifier|type|

#### -0--l ~ -I ~

If the base type is an undeclared identifier, it must be declared in the same type declaration part as the pointer type.

You can assign a value to a pointer variable with the *New* proce- dure, the @ operator, or the *Ptr* function. *New* allocates a new memory area in the application heap for a dynamic variable and stores the address of that area in the pointer variable. The @ operator directs the pointer variable to the memory area containing any existing variable or procedure or function entry point, including variables that already have identifiers. *Ptr* points the pointer variable to a specific memory address.

The reserved word denotes a pointer-valued constant that doesn't point to anything.

The predefined type *Pointer* denotes an untyped pointer; that is, a pointer that doesn't point to any specific type. Variables of type *See Chapter* 5$ *sectionPointer* can't be dereferenced; writing the pointer symbol" after *entitled "Pointers and* such a variable is an error. Generic pointers, however, can be *dynamic variables" on page* *56 for the syntax of* typecast to allow dereferencing. Like the value denoted by the *referencing the dynamic* word **nil,** values of type *Pointer* are compatible with all other *variable pointed to by* a pointer types. *pointer variable.*

##### Type PChar

Turbo Pascal has a predefined type, *Pehar,* to represent a pointer to a null-terminated string. The *System* unit declares *pehar* as

type PChar = AChar;

Turbo Pascal supports a set of *extended syntax* rules to facilitate handling of null-terminated strings using the *pehar* type. For a complete discussion of this topic, see Chapter 16, "Using null- terminated strings."

*Chapter* 4, *Types*

**types**

Standard Pascal regards procedures and functions as program parts that can be executed through procedure or function calls. Turbo Pascal has a much broader view of procedures and functions: It allows procedures and functions to be treated as entities that can be assigned to variables and passed as parame- ters. Such actions are made possible through *procedural types.*

A procedural-type declaration specifies the parameters and, for a function, the result type.

procedural type

formal parameter list

In essence, the syntax for writing a procedural-type declaration is exactly the same as for writing a procedure or function header, except that the identifier after the **procedure or function** keyword is omitted. Some examples of procedural-type declarations follow:

type Proc = procedure;

|Proc|procedure;|||
|---|---|---|---|
|SwapProc|procedure(var|X, Y:|Integer);|
|StrProc|procedure(S:|||
|MathFunc|function(X:|Real): Real;||
|DeviceFunc|function(var|F: Text):|Integer;|
|MaxFunc|function|B: Real;|F: MathFunc):|

= = string); = = = (A, Real;

The parameter names in a procedural-type declaration are purely -decorative-they have no effect on the declaration's meaning.

Turbo Pascal doesn't let you declare functions that return proce- dural-type values; a function result must be a string, real, integer, char, boolean, pointer, or user-defined enumeration-type value. But you can return the address of a procedure or function using a function result of type *Pointer* and then typecast it to the procedural type you desire.

##### Procedural values

A variable of a procedural type can be assigned a *procedural value.* Procedural values can be one of these:

*Language Guide*

- The value **nil**
- A variable reference of a procedural type
- A procedure or function identifier In the context of procedural values, a procedure or function declaration can be viewed as a special kind of constant declaration, the value of the constant being the procedure or function. For example, given the following declarations: var P: SwapProc; F: MathFunc;

|procedure|Swap(var|A, B: Integer);|far;|
|---|---|---|---|
|var||||
|Temp: begin|Integer;|||
|Temp A := B; B := Temp; end;|:= A;|||
|function begin|Tan (Angle:|Real); far;||
|Tan := end;|Sin(Angle)|/ Cos (Angle)|;|

the variables P and *F* can be assigned values as follows:

P := Swap; F := Tan;

|and calls can|be made using|P and F|as follows:|
|---|---|---|---|
|P (I, J);|{Equivalent|to Swap(I,|J)}|
|X := F(X);|{Equivalent|to X := Tan(X)|}|

Using a procedural variable that has been assigned the value **nil** in a procedure statement or a function call results in an error. **nil** is intended to indicate that a procedural variable is unassigned, and whenever there is a possibility that a procedural variable is **nil,** procedure statements or function calls involving that procedural by a test:

|||variable|should|be guarded|
|---|---|---|---|---|
||||@P <>|then P(I,|
|"Procedural|types|in||@|
|expressions"|on page|44.|||

##### if nil J);

Notice the use of the operator to indicate that *P* is being ex- amined rather than being called.

*Chapter* 4, *Types*

**compatibility** To be considered compatible, procedural types must have the same number of parameters, and parameters in corresponding positions must be of identical types. Finally, the result types of functions must be identical. Parameter names have no significance when determining procedural-type compatibility.

The value **nil** is compatible with any procedural type.

To be used as procedural values, procedures and functions must be declared with a **far** directive or compiled in the **{$F+}** state. Also, standard procedures and functions, nested procedures and functions, methods, **inline** procedures and functions, and **interrupt** procedures can't be used as procedural values.

Standard procedures and functions are the ones declared by the *System* unit, such as *WriteLn, ReadLn, Chr,* and *Ord.* To use a standard procedure or function as a procedural value, write a "shell" around it. For example, the following function *FSin* is assignment-compatible with the *MathFunc* type declared above.

function FSin(X: Real): Real; far; begin FSin : = Sin (X);

|FSin|: = Sin|(X);||
|---|---|---|---|
|end;||||

A procedure or function is *nested* when it's declared within another procedure or function. Such nested procedures and functions can't be used as procedural values.

#### Identical and compatible types

Two types can be the same, and this sameness (identity) is mandatory in some contexts. At other times, the two types need only be compatible or merely assignment-compatible. They are identical when they are declared with, or their definitions stem from, the same type identifier.

##### Type identity

Type identity is required only between actual and formal variable parameters in procedure and function calls.

*Language Guide*

Two types-say, *Tl* and T2-are identical if one of the following is true: *Tl* and *T2* are the same type identifier; *Tl* is declared to be equivalent to a type identical to *T2.*

The second condition connotes that *Tl* doesn't have to be de- clared directly to be equivalent to *T2.* The type declarations

Tl = Integer; T2 = Tl; T3 = Integer; T4 = T2;

result in *Tl, T2, T3, T4,* and *Integer* as identical types. The type declarations

= set

|T5|of Integer;|
|---|---|
|T6|of Integer;|

= set

don't make *T5* and *T6* identical because set of Integer isn't a type identifier. Two variables declared in the same declaration, for example,

Vl, V2: set of Integer;

are of identical types-unless the declarations are separate. The declarations

set

|Vl:||of|Integer;|
|---|---|---|---|
|V2: V3: V4:|Integer; Integer;|of|Integer;|

set

mean *V3* and *V* 4 are of identical type, but not *Vl* and *V2.*

**compatibility** Compatibility between two types is sometimes required, such as in expressions or in relational operations. Type compatibility is important, however, as a precondition of assignment compatibility.

Type compatibility exists when at least one of the following conditions is true:

- Both types are the same.
- Both types are real types.
- Both types are integer types.
- One type is a subrange of the other.
- Both types are subranges of the same host type.
*Chapter* 4, *Types*

|• Both. types|are set|types with|compatible|base types.|||
|---|---|---|---|---|---|---|
|• Both types components.|are packed|string|types with|an identical|number|of|
|• One type|is a string|type and|the other is|either a|string type,||
|packed|string type,|or Char type.|||||
|• One type|is Pointer|and the other|is any|pointer type.|||
|• One type|is PChar|and the other|is a zero-based|character||array|
|of the form|array[O|.. X] of Char.|(This applies|only|||
|extended|syntax is|enabled with|the {$X+}|directive.)|||
|• Both types|are pointers|to identical|types.|(This applies|only||
|when type-checked directive.)||pointers|are enabled|with the|{$T +}||
|• Both types|are procedural|types|with identical|result|types,|an|
|identical|number|of parameters,|and a one-to-one||identity||
|between|parameter|types.|||||

when

**compatibility** Assignment compatibility is necessary when a value is assigned to something, such as in an assignment statement or in passing value parameters.

A value of type *T2* is assignment-compatible with a type *T1* (that is, *T1* := *T2* is allowed) if any of the following are *True:*

- *T1* and *T2* are identical types and neither is a file type or a structured type that contains a file-type component at any level of structuring.
- *T1* and *T2* are compatible ordinal types, and the values of type *T2* falls within the range of possible values of *T1 .*
- *T1* and *T2* are real types, and the value of type *T2* falls within the range of possible values of *T l'*
- *T1* is a real type, and *T2* is an integer type.
- *T* 1 and *T* 2 are string types.
- *T1* is a string type, and *T2* is a *Char* type.
- *T1* is a string type, and *T2* is a packed string type.
- *T1* and *T2* are compatible, packed string types.
- *T1* and *T2* are compatible set types, and all the members of the value of type *T* fall within the range of possible values of *T l'*
- *T1* and *T2* are compatible pointer types.
*Language Guide*

*T1* is a *PChar* and *T2* is a string constant. (This applies only when extended syntax is enabled {$X+}.)

- *T1* is a *PChar* and *T2* is a zero-based character array of the form array[O .. X] **of** *Char.* (This applies only when extended syntax is enabled {$X+}.)
- *T1* and *T2* are compatible procedural types.
- *T1* is a procedural type, and *T2* is a procedure or function with an identical result type, an identical number of parameters, and a one-to-one identity between parameter types.
- *T2* is assignment-compatible with an object type *T1* if *T2* is an object type in the domain of *T l'*
- A pointer type *P2,* pointing to an object type *T2,* is assignment- compatible with a pointer type P 1, pointing to an object type *T* 11 if *T* 2 is' in the domain of *T l'* A compile-time error occurs when assignment compatibility is necessary and none of the items in the preceding list are true.
#### The type declaration part

Programs, procedures, functions, and methods that declare types have a *type declaration part.* This is an example of a type declara- tion part:

type TRange = Integer;

|TRange|Integer;|||
|---|---|---|---|
|TNumber|Integer;|||
|TColor|(Red, Green,|Blue);||
|TCharVal|Ord('A')|Ord('Z');||
|TTestIndex|1 100;|||
|TTestValue|-99|99;||
|TTestList|array|[TTestIndexj|of TTestValue;|
|PTestList|~TTestList;|||
|TDate|object|||
|Year:|Integer;|||
|Month:|1. .12;|||
|Day:|1..31;|||
|procedure|SetDate(D,|M, Y:|Integer);|
|function end;|ShowDate:|String;||

= = = .. = .. = .. = = =

*Chapter* 4, *Types*

=

|TMeasureData|record||
|---|---|---|
|When: TDatei|||
|Count: Data: PTestListi endi|TTestIndexi||
|TMeasureList TName string[80]i|array[1|50] of TMeasureDatai|
|TSex (Male,|Female)i||
|PPersonData|ATPersonDatai||
|TPersonData|record||
|Name, FirstName: Age: Integeri|TNamei||
|Married:|Booleani||
|TFather,|TChild, TSibling:|PPersonDatai|
|case S:|TSex of||
|Male:|(Bearded: Boolean);||
|Female: endi|(Pregnant:|Boolean)i|
|TPersonBuf|array[O.. SizeOf(TPersonData)-l]||
|TPeople|of TPersonDatai||

= **..** = = = =

= **of** Byte; = **file**

##### In the example, Range, Number, and Integer are identical types.

***TTestIndex* is compatible and assignment-compatible with, but not identical to, the types *Number, Range,* and *Integer.* Notice the use**

##### of constant expressions in the declarations of TCharVal and

##### TPersonBuf

***Language Guide***

variable declaration

absolute clause

The type given for the variable(s) can be a type identifier previously declared in a **type** declaration part in the same block, in an enclosing block, or in a unit; it can also be a new type definition.

When an identifier is specified within the identifier list of a variable declaration, that identifier is a variable identifier for the block in which the declaration occurs. The variable can then be referred to throughout the block, unless the identifier is rede- clared in an enclosed block. Redeclaration creates a new variable using the same identifier, without affecting the value of the original variable.

##### An example of a variable declaration part follows:

var X, Y, Z: Real; I, J, K: Integer; Digit: .. 9;

*Chapter* 5, *Variables and typed constants*

C: Color; Done, Error: Boolean; Operator: (Plus, Minus, Times);

|Operator:|(Plus, Minus,|Times);|
|---|---|---|
|Hue1, Hue2: Today: Date; Results: MeasureList; P1, P2: Person;|of Color;||
|Matrix: array[1|10, 1|10] of Real;|

set

##### .. ..

Variables declared outside procedures and functions are called *global variables,* and they reside in the *data segment.* Variables declared within procedures and functions are called *local variables,* and they reside in the *stack segment.*

The maximum size of the data segment is 65,520 bytes. When a program is linked (this happens automatically at the end of the compilation of a program), the global variables of all units used by the program, as well as the program's own global variables, are placed in the data segment.

If you need more than 65,520 bytes of global data, you should

|"Pointers|and|
|---|---|
|variables"|on|
|page|56.|

allocate the larger structures as dynamic variables. *dynamic*

##### The stack segment

|The size|of the stack|segment is|set through|a $M compiler|||
|---|---|---|---|---|---|---|
||can be|from|1,024|to 65,520 bytes.|The||
|default stack-segment||size is 16,384|bytes.||||
|Each time|a procedure|or function|is activated|(called),|it allocates||
|a set of local|variables|on the stack.|On exit,|the local|variables|are|
|. disposed|of. At any|time during|the execution|of a program,||the|
|total size|of the local|variables|allocated|the active|procedures||
|and functions|can't|the|size of the|stack segment.|||
|The $S compiler|directive|is used|to include|stack-overflow|||
|checks in|the code.|the default|{$S+} state,|code is|generated|to|
|check for|stack overflow|at the|beginning|of each procedure||and|
|function.|the {$S-}|state, no such|checks|are performed.|||
|A stack overflow|can|cause a system|crash,|so|turn off|stack|
|checks unless|you're|absolutely|sure that|overflow|will never||

directive-it anywhere

by exceed

In

In

don't an occur.

*Language Guide*

|Variables|can be declared|to reside|at specific|memory|addresses,|
|---|---|---|---|---|---|
|and are|then called|variables.|The declaration||of such|
|variables|must include|an absolute|clause|following|the type:|

*absolute*

The variable declaration's identifier list can only specify one identifier when an **absolute** clause is present.

The first form of the **absolute** clause specifies the segment and offset at which the variable is to reside:

CrtMode : Byte absblute $0040:$0049;

The first constant specifies the segment base, and the second specifies the offset within that segment. Both constants must be within the range $0000 to $FFFF (0 to 65,535).

The second form of the **absolute** clause is used to declare a variable "on top" of another variable, meaning it declares a variable that resides at the same memory address as another variable:

var Str: string[32]; StrLen: Byte absolute Str;

This declaration specifies that the variable *StrLen* should start at the same address as the variable *Str,* and because the first byte of a string variable contains the dynamic length of the string, *StrLen* will contain the length of *Str.*

**references** A variable reference signifies one of the following:

ill A variable

- A component of a structured-or string-type variable
- A dynamic variable pointed to by a pointer-type variable
*Chapter* 5, *Variables and typed constants*

This is the syntax of a variable reference:

variable reference

The syntax for a variable reference allows an expression that computes a pointer-type value. The expression must be followed by a qualifier that dereferences the pointer value (or indexes the pointer value if the extended syntax is enabled with the **{$X+}** directive) to produce an actual variable reference.

A variable reference can contain zero or more qualifiers that modify the meaning of the variable reference.

qualifier

An array identifier with no qualifier, for example, references the entire array:

Results

An array identifier followed by an index denotes a specific component of the array-in this case, a structured variable:

Results[Current + 1]

With a component that is a record or object, the index can be followed by a field designator. Here the variable access signifies a specific field within a specific array component:

Results[Current + 1] .Data

The field designator in a pointer field can be followed by the pointer symbol (/\) to differentiate between the pointer field and the dynamic variable it points to:

Results[Current + 1] .Data A

If the variable being pointed to is an array, indexes can be added to denote components of this array:

Results[Current + 1] .DataA[J]

*Language Guide*

# ~ expression f--r-CD--

##### .... ------t01+1------I

##### The index expressions select components in each corresponding

dimension of the array. The number of expressions can't exceed the number of index types in the array declaration. Also, each expression's type must be assignment-compatible with the corresponding index type.

When indexing a multidimensional array, multiple indexes or multiple expressions within an index can be used interchange- ably. For example,

Matrix [I] [J]

##### is the same as

Matrix[I, J]

You can index a string variable with a single index expression, whose value must be in the range *O .. N,* where N is the declared size of the string. This accesses one character of the string value, with the type *Char* given to that character value.

The first character of a string variable (at index 0) contains the dynamic length of the string; that is, *Length(S)* is the same as *Ord(S[oJ).* If a value is assigned to the length attribute, the compiler doesn't check whether this value is less than the declared size of the string. It's possible to index a string beyond its current dynamic length. The characters read are random and assignments beyond the current length don't affect the actual value of the string variable.

When the extended syntax is enabled (using the {$X+} compiler directive), a value of type *PChar* can be indexed with a single index expression of type *Word.* The index expression specifies an *offset* to add to the character pointer before it's dereferenced to produce a *Char* type variable reference.

*Chapter* 5, *Variables and typed constants*

Records and field A specific field of a record variable is denoted by a variable designators reference that refers to the record variable, followed by a field designator specifying the field.

field designator-()-l field identifier **f--**

These are examples of a field designator:

Today.Year Results[l] .Count Results [1]. When.Month

In a statement within a **with** statement, a field designator doesn't have to be preceded by a variable reference to its containing record.

Object component The format of an object component designator is the same as that designators of a record field designator; that is, it consists of an instance (a variable reference), followed by a period and a component identi- fier. A component designator that designates a method is called a *method designator.* A **with** statement can be applied to an instance of an object type. In that case, the instance and the period can be omitted in referencing components of the object type.

The instance and the period can also be omitted within any method block, and when they are, the effect is the same as if *Self* and a period were written before the component reference.

Pointers and dynamic The value of a pointer variable is either **nil** or the address of a variables dynamic variable.

The dynamic variable pointed to by a pointer variable is refer- enced by writing the pointer symbol (/\) after the pointer variable.

You create dynamic variables and their pointer values with the procedures *New* and *GetMem.* You can use the @ (address-of) operator and the function *Ptr* to create pointer values that are treated as pointers to dynamic variables.

**nil** doesn't point to any variable. The results are undefined if you access a dynamic variable when the pointer's value is **nil** or undefined. These are examples of references to dynamic variables:

Pi" Pl".Sibling" Results[l] .Data"

*Language Guide*

**typecasts** A variable reference of one type can be changed into a variable type through a *variable typecast.*

|||reference|of another|
|---|---|---|---|
|||variable|typecast type identifier|
|The|programmer|is||
|responsible|for determining|||
|the validity|typecast.|||

variable reference

When a variable typecast is applied to a variable reference, the variable reference is treated as an instance of the type specified by *of* a the type identifier. The size of the variable (the number of bytes occupied by the variable) must be the same as the size of the type denoted by the type identifier. A variable typecast can be followed by one or more qualifiers, as allowed by the specified type.

##### These typecasts:

|are examples|of|variable|
|---|---|---|
|type|||
|TByteRec|record||
|La, Hi: end;|Byte;||
|TWordRec|record||
|Low, High: end;|Word;||
|TPtrRec|record||
|Ofs, Seg: end;|Word;||
|PByte var B: Byte; W: Word; L: Longint; P: Pointer; begin W := $1234;|"Byte;||
|B := TByteRec(W)|.Lo;||
|TByteRec(W) L := $01234567;|.Hi :=|0;|
|W := TWordRec(L)|.Low;||
|B := TByteRec B := PByte(L)"; P := Ptr($40,$49);|(TWordRec|(L) .Low)|
|W := TPtrRec(P)|.Seg;||
|Inc (TPtrRec end.|(P) .Ofs,|4);|

=

=

=

=

.Hi;

*Chapter* 5, *Variables and typed constants*

Pascal fully supports variable typecasts involving procedural types. For example, given the declarations

type Func = function {X: Integer): Integer; var F: TFunc; P: Pointer; N: Integer;

following

|you can construct|the|assignments:||||
|---|---|---|---|---|---|
|F : = Func|( P);|{Assign|procedural|value in|P to F }|
|Func{P)|:= F;|{Assign|procedural|value in|F to P }|
|@F := P;||{Assign|pointer|value in|P to F }|
|P := @F;||{Assign|pointer|value in|F to P }|
|N := F(N);|||{Call|function|via F }|
|N : Func|(P) (N);||{Call|function|via P }|

=

In particular, notice that the address operator (@), when applied to a procedural variable, can be used on the left side of an assignment. Also, notice the typecast on the last line to call a function via a pointer variable.

##### Typed constants

Typed constants can be compared to initialized variables- variables whose values are defined on entry to their block. Unlike an untyped constant, the declaration of a typed constant specifies both the type and the value of the constant.

typed constant declaration

#### L-I identifier ~ typed constant ~

*Language Guide*

typed constant-~-+I ::======---------.

procedural constant

Typed constants can be used exactly like variables of the same type, and can appear on the left-hand side in an assignment state- ment. Note that typed constants are initialized *only once-at* the beginning of a program. Therefore, for each entry to a procedure or function, the locally-declared typed constants aren't reinitialized.

In addition to a normal constant expression, the value of a typed constant can be specified using a *constant-address expression.* A constant-address expression is an expression that involves taking the address, offset, or segment of a global variable, a typed con- stant, a procedure, or a function. Constant-address expressions can't reference local variables (stack based) or dynamic (heap- based) variables, because their addresses can't be computed at compile time.

**constants** Declaring a typed constant as a simple type specifies the value of the constant:

const Maximum: Integer = 9999;

|Maximum:|Integer|9999;|
|---|---|---|
|Factor:|Real|-0.1;|
|Breakchar:|Char|#3;|

= =

|As mentioned|earlier, the|value|of a typed|constant|can be|
|---|---|---|---|---|---|
|specified|using a constant-address||expression,|that|is,|
|expression|that takes|the address,|offset,|or segment|of a global|
|variable,|a typed constant,|a procedure,||or a function.|For|

an

example,

var Buffer: array[O .. 1023] of Byte;

|Buffer:|array[O|1023]|of Byte;|
|---|---|---|---|
|const||||
|BufferOfs:|Word|Ofs(Buffer);||
|BufferSeg:|Word|Seg(Buffer);||

= =

*Chapter* 5, *Variables and typed constants*

Because a typed constant is actually a variable with a constant value, it can't be interchanged with ordinary constants. For example, it can't be used in the declaration of other constants or types:

const Min: Integer = 0; Max: Integer = 99; type

|type|||
|---|---|---|
|TVector|array [Min|Max] of Integer;|

= ..

The *TVector* declaration is invalid, because *Min* and *Max* are typed constants.

##### String-type

**constants** The declaration of a typed constant of a string type specifies the maximum length of the string and its initial value:

const Heading: string[7] = 'Section';

|Heading:|string[7]|'Section';|
|---|---|---|
|NewLine:|string[2]|#13#10;|
|TrueStr:|string[5]|'Yes';|
|FalseStr:|string[5]|'No';|

= = =

##### Structured-type

**constants** The declaration of a structured-type constant specifies the value of each of the structure's components. Turbo Pascal supports the declaration of array, record, object, and set-type constants. File- type constants and constants of array, record, and object types that contain file-type components aren't allowed.

Array-type constants The declaration of an array-type constant specifies the values of the components. The values are enclosed in parentheses and separated by commas.

array constant-cD-r' typed constant ~

#### ......--~O)+o----.I

This is an example of an array-type constant:

type TStatus = (Active, Passive, Waiting);

|TStatus|(Active,|Passive,|Waiting);|
|---|---|---|---|
|TStatusMap const|array[Status]||of|
|StatStr:|TStatusMap|('Active',||

= string[7];

= 'Passive', 'Waiting');

*Language Guide*

##### StatStr, which can be

used to convert values of type *TStatus* into their corresponding string representations. These are the components of *StatStr:*

StatStr[Active] = 'Active' StatStr[Passive] = 'Passive' StatStr[Waiting] = 'Waiting'

The component type of an array constant can be any type except a file type. Packed string-type constants (character arrays) can be specified both as single characters and as strings. The definition

const Digits: array[0 9] of Char = '1', '2', '3', '4', '5',

|||..|('0',|
|---|---|---|---|
|Digits:|array[0|9] of Char|=|
||,|||

'6', '7', 8', '9');

can be expressed more conveniently as

const Digits: array[0 .. 9] of Char = '0123456789';

When the extended syntax is enabled (using a {$X+} compiler directive), a zero-based character array can be initialized with a string that is shorter than the declared length of the array. For example,

|const||
|---|---|
|FileName array[O|79] of Char 'TEST.PAS';|

##### = .. =

In such cases, the remaining characters are set to NULL (#0) and the array effectively contains a null-terminated string.

Multidimensional-array constants are defined by enclosing the constants of each dimension in separate sets of parentheses, separated by commas. The innermost constants correspond to the rightmost dimensions. The declaration

type Cube = array[O .. l, 0 .. 1, 0 .. 1] of Integer;

|Cube|array[O|0 1, 0|1] of Integer;||
|---|---|---|---|---|
|const|||||
|Maze:|Cube|(0, 1), (2,|3)), ((4, 5),|(6, 7)));|

##### = ((

*Maze* with the following values:

|provides|an|initialized|array|
|---|---|---|---|
|Maze[O,|0,|0]|0|
|Maze[O,|0,|1]|1|
|Maze[O,|1,|0]|2|
|Maze[O,|1,|1]|3|
|Maze[l,|0,|0]|4|
|Maze[l,|0,|1]|5|

= = = = = =

*Chapter* 5, *Variables and typed constants*

0] = 6 Maze[l, 1, 1] = 7

##### Record-type constants The declaration of a record-type constant specifies the identifier

**and value of each field, enclosed in parentheses and separated by semicolons.**

**record constant**

L.cD-C-f-ie-ld-id-e-nt-ifi-er---'~ typed constant TeD-- **These are examples of record constants:** **type** TPoint = **record** ~, Y: Real; **end;** TVector = **array[O .**. 1] **of** Point; TMonth = (Jan, Feb, Mar, Apr, May, Jun, Jul, Aug, Sep, Oct, Nov, Dec); TDate = **record** D: 1. .31; M: Month; Y: 1900 .. 1999; **end;** **const** Origin: TPoint = (X: 0.0; Y: 0.0); Line: TVector = ((X:-3.1; Y: 1.5), (X: 5.8; Y: 3.0)); SomeDay: TDate = (D: 2; M: Dec; Y: 1960); **The fields must be specified in the same order as they appear in** **the definition of the record type. If a record contains fields of file** **types, the constants of that record type can't be declared. If a** **record contains a variant, only fields of the selected variant can be** **specified. If the variant contains a tag field, then its value must be specified.**
##### Object-type constants The declaration of an object-type constant uses the same syntax as

**the declaration of a record-type constant. No value is, or can be,** **specified for method components. Referring to the earlier object- type declarations starting on page 34, these are examples of**

**object-type constants:**

***Language Guide***

|ZeroPoint:|TPoint|(X: Oi Y: O)i|||
|---|---|---|---|---|
|ScreenRect:|TRect|(A: (X: Oi Y:|0) i B: (X:|80i Y: 25));|
|CountField:|TNumField|(X: 5; Y:|20i Len:|4; Name:|
|Value:|0; Min:-999;|Max: 999)i|||

= = = **nili**

**Constants of an object type that contains virtual methods need *not* be initialized through a constructor call-this initialization is**

##### handled automatically by the compiler.

**Set-type constants Just like a simple-type constant, the declaration of a set-type** **constant specifies the value of the set using a constant expression.** **Here are some examples:**

**type**

|Digits|set of O •• 9;|||
|---|---|---|---|
|Letters const|set of 'A'|||
|EvenDigits:|Digits|[0, 2, 4, 6,|8];|
|Vowels:|Letters ['A',||lUI,|
|HexDigits:|set of 'O'|=|'A'|

Digits = **set of** O •• 9; = .. 'Z';

= = 'E', 'I', '0', *'Y']i* .. 'z' ['0' .. '9', .. 'F', *'a' ... f']i*

##### Pointer-type constants The declaration of a pointer-type constant uses a constant-address

##### expression to specify the pointer value. Some examples follow:

**type**

|TDirection|(Left,|Right, Up,|Down);||
|---|---|---|---|---|
|TStringptr|AString;||||
|PNode|ATNode;||||
|TNode|record||||
|Next:|PNode;||||
|Symbol:|TStringPtr;||||
|Value: end; const|TDirection;||||
|Sl: string[4]|, DOWW|i|||
|S2: string[2]|'UP'i||||
|S3: string|[5] 'RIGHT'i||||
|S4: string|[4] 'LEFT'i||||
|N1: TNode|(Next:|Symbol:|@Sli Value:|Down) i|
|N2: TNode|(Next:|@Nl; Symbol:|@S2; Value:|Up);|
|N3: TNode|(Next:|@N2i Symbol:|@S3i Value:|Right);|
|N4: TNode|(Next:|@N3; Symbol:|@S4; Value:|Left);|
|DirectionTable:|PNode|@N4;|||

TDirection = (Left, Right, Up, Down); = = =

= **nili** = = = =

***Chapter* 5, *Variables and typed constants***

##### When the extended syntax is enabled (using a {$X+} compiler

**directive), a typed constant of type *PChar* can be initialized with a string constant. For example,**

**const** Message: PChar = 'Program terminated';

|Message:|PChar|'Program|terminated';||
|---|---|---|---|---|
|Prompt:|PChar|'Enter|values:||
|Digits:|array[O|9) of|PChar||
|'Zero',|'One',|'Two', 'Seven',|'Three',|'Four', 'Nine');|

##### = ';

##### .. = (

'Five', 'Six', 'Eight',

**The result is that the pointer now points to an area of memory** **that contains a zero-terminated copy of the string literal. See** **Chapter 16, "Using null-terminated strings," for more information.**

##### Procedural-type

**constants** A **procedural-type constant must specify the identifier of a proce-** **dure or function that is assignment-compatible with the type of the constant, or it must specify the value nil.**

**procedural constant**

**Here's an example:**

**type** TErrorProc = procedure (ErrorCode: Integer);

|TErrorProc|procedure|(ErrorCode:|Integer);|
|---|---|---|---|
|procedure begin|DefaultError(ErrorCode:||Integer);|
|WriteLn('Error end; const|" ErrorCode,|,||
|ErrorHandler:|TErrorProc|DefaultError;||

**far;**

.');

=

***Language Guide***

-A unary operator always precedes its operand (for example,*-B).*

In more complex expressions, rules of precedence clarify the order in which operations are performed.

|Operators|Precedence|Categories|
|---|---|---|
|@,not|first (high)|unary operators|
|*, /, diY, mod, shl, shr|and, second|multiplying operators|
|+,., or, xor|third|adding operators|
|=, <>, <, >, <=, >=,|in fourth (low)|relational operators|

There are three basic rules of precedence:

- An operand between two operators of different precedence is bound to the operator with higher precedence.
- An operand between two equal operators is bound to the one on its left.
- Expressions within parentheses are evaluated prior to being treated as a single operand.

variable reference unsigned constant f-----------t

value typecast f-------------t address factor f---------------'

A function call activates a function and denotes the value returned by the function. See "Function calls" on page 76.

A set constructor denotes a value of a set type. See "Set constructors" on page 76.

A value typecast changes the type of a value. See "Value typecasts" on page 77.

An address factor computes the address of a variable, procedure, function, or method. See "The @ operator" on page 75.

##### An unsigned constant has the following syntax:

unsigned constant unsigned number character string

*Language Guide*

**These**

|are some|examples|of factors:|||
|---|---|---|---|---|
||||{Variable|reference|
|@X|||Pointer to|a variable|
|15|||Unsigned|constant|
|(X + Y +|Z)||{SUbexpression||
|Sin(X / 2)|||{Function||
|exi t [0 ••|9 A|•• Z 1|Set|constructor|
|not Done|||Negation of|a Boolean|
|Char(Digit|+ 48)||{Value|typecast|

x

call I I I I I I I I I

**Terms apply the multiplying operators to factors:**

**term**

**Here are some examples of terms:**

##### x * Y

Z / (1-Z) Y **shl** 2 (X <= Y) **and** (Y < Z)

**Simple expressions apply adding operators and signs to terms:**

**simple expression**

**Here are some examples of simple expressions:**

X + Y -x Hue1 + Hue2 I * J + 1

##### An expression applies the relational operators to simple expressions:

**6, *Expressions***

##### Jr--:::::::::-----;:::======:;-r-

~---,.~-.j simple expression

##### Here are some examples of expressions:

##### x = 1.5

Done <> Error (I < J) = (J < K) C in Huel

Operators are classified as arithmetic operators, logical operators, string operators, character-pointer operators, set operators, relational operators, and the @ operator.

**operators** The following tables show the types of operands and results for binary and unary arithmetic operations.

|Binary arithmetic|operations Table|6.2|Operator|
|---|---|---|---|
|The + operator string or the +,-, and a/so used|is a/so set operator, operators set operators.|used and are|+|

**Operation Operand types Result type**

as addition integer type integer type a real type real type * as subtraction integer type integer type real type real type

* multiplication integer type integer type
real type real type division integer type real type real type real type **div** integer division integer type integer type **mod** remainder integer type integer type

*Language Guide*

6.1

|Unary arithmetic|Operator|Operation|Operand|types|Result type|
|---|---|---|---|---|---|
||+|sign identity sign negation|integer real type integer real type|type type|integer type real type integer type real type|

operations

Any operand whose type is a subrange of an ordinal type is treated as if it were of the ordinal type.

|a|of|||
|---|---|---|---|
|For definition|common||div, or mod|
|types,|see page|25.||
||||+,|

If both operands of a **+,-, *,** operator are of an integer type, the result type is of the common type of the two operands.

If one or both operands of a**-,** or * operator are of a real type, the type of the result is *Real* in the **{$N-}** state or *Extended* in the **{$N+}** state.

If the operand of the sign identity or sign negation operator is of an integer type, the result is of the same integer type. If the operator is of a real type, the type of the result is *Real* or *Extended.*

The value of X / Y is always of type *Real* or *Extended* regardless of the operand types. A run-time error occurs if Y is zero.

The value of *I* **div** J is the mathematical quotient of *I* / J, rounded in the direction of zero to an integer-type value. A run-time error occurs if J is zero.

The **mod** operator returns the remainder obtained by dividing its

|two operands;|that is,||
|---|---|---|
|I mod J|I -(I div|J) J|
|||mod|

= *

The sign of the result of is the same as the sign of *I.* A run- time error occurs if J is zero.

##### Logical operators

The types of operands and results for logical operations are shown in Table 6.4.

*Chapter* 6, *Expressions*

||Logical|operations|6.4|Operator|
|---|---|---|---|---|
|The not|operator|is operator.|unary|not and|
|||||or|
|||||xor|
|||||shl|
|||||shr|

||Operation||Operand|types|Result|type|
|---|---|---|---|---|---|---|
||bitwise bitwise bitwise bitwise shift left shift right|negation and or xor|integer integer integer integer integer integer|type type type type type type|Boolean Boolean Boolean Boolean Boolean Boolean||
|the operand|of the|not operator|is of|integer|type, the|result|
|is of the same|integer|type.|||||
|both operands|of an|and, or,|or xor operator|are|of an integer||
|type, the|type|is the common|type|of the two|operands.||
|The operations|I shl|and I shr|shift the|value of|I to the|left right|
|by bits.|result type|is the|same as|the type of|I.||

a

##### If an

If result

J J J The

Boolean

operators The types of operands and results for Boolean operations are shown in Table 6.5.

|Boolean|operations Table|6.5|Operator|
|---|---|---|---|
|The not operator|is operator.|unary|not and|
||||or|
||||xor|

Operation Operand types Result type

a negation Boolean type *Boolean* logical and Boolean type *Boolean* logical or Boolean type *Boolean* logical xor Boolean type *Boolean*

Normal Boolean logic governs the results of these operations. For instance, *A* and B is *True* only if both *A* and B are *True.*

Turbo Pascal supports two different models of code generation for the and and or operators: complete evaluation and short- circuit (partial) evaluation.

Complete evaluation means that every operand of a Boolean expression built from the and and or operators is guaranteed to be evaluated, even when the result of the entire expression is already known. This model is convenient when one or more operands of an expression are functions with side effects that alter the meaning of the program.

Short-circuit evaluation guarantees strict left-to-right evaluation and that evaluation stops as soon as the result of the entire expression becomes evident. This model is convenient in most cases because it guarantees minimum execution time, and usually

*Language Guide*

##### minimum code size. Short-circuit evaluation also makes possible

the evaluation of constructs that would not otherwise be legal. For example,

|while (I <=|Length(S))|and (S[I]|<> ' ') do|
|---|---|---|---|
|Inc (I);||||
|while (P <> p := PA.Next;|and|(pA.Value|<> 5) do|

nil)

In both cases, the second test is not evaluated if the first test is *False.*

The evaluation model is controlled through the $B compiler directive. The default state is {$B-}, and in this state, the compiler generates short-circuit evaluation code. In the {$B+} state, the compiler generates complete evaluation.

Because Standard Pascal doesn't specify which model should be used for Boolean expression evaluation, programs dependent on either model are not truly portable. You may decide, however, that sacrificing portability is worth the gain in execution speed and simplicity provided by the short-circuit model.

operator

The types of operands and results for string operation are shown in Table 6.6.

|String operation Table|6.6|Operator|Operation|Operand|types|Result|type|
|---|---|---|---|---|---|---|---|
|||+|concatenation|string packed|type, type, or string|string type|type|
|||||+||||
|||||||+||

*Char*

Turbo Pascal allows the operator to be used to concatenate two string operands. The result of the operation 5 T, where Sand *T* are of a string type, a *Char* type, or a packed string type, is the concatenation of 5 and *T.* The result is compatible with any string type (but not with *Char* types and packed string types). If the resulting string is longer than 255 characters, it's truncated after character 255.

Character-

pointer operators The extended syntax (enabled using a {$X+} compiler directive) supports a number of character-pointer operations. The plus (+) and minus (-) operators can be used to increment and decrement

*Chapter* 6, *Expressions*

P and Q are values of type *PChar* and *I* is a value of type *Word,* these constructs are allowed:

**Operation Result**

P + *I* Add *I* to the offset part of P *I* + P Add *I* to the offset part of P P-*I* Subtract *I* from the offset part of P P-Q Subtract offset part of Q from offset part of P

The operations P + *I* and *I* + P adds *I* to the address given by P, producing a pointer that points *I* characters after P. The operation P-*I* subtracts *I* from the address given by P, producing a pointer that points *I* characters before P.

The operation P- Q computes the distance between Q (the lower address) and P (the higher address), resulting in a value of type *Word* that gives the number of characters between Q and P. This operation assumes that P and Q point within the same character array. If the two character pointers point into different character arrays, the result is undefined.

The types of operands for set operations are shown in Table 6.8.

**Operator Operation Operand types**

+ union compatible set types difference compatible set types * intersection compatible set types

The results of set operations conform to the rules of set logic:

- An ordinal value C is in *A* + B only if C is in *A* or B.
- An ordinal value C is in *A*-B only if C is in *A* and not in B.
- An ordinal value C is in *A* * B only if C is in both *A* and B. If the smallest ordinal value that is a member of the result of a set operation is *A* and the largest is B, then the type of the result is **set of** *A .. B.*
*Language Guide*

operators The types of operands and results for relational operations are shown in Table 6.9.

Table 6.9

Relational operations Operator type Operation Operand types Result type

= equal compatible simple, *Boolean* pointer, set, string, or packed string types <> not equal compatible simple, *Boolean* pointer, set, string, or packed string types < less than compatible simple, *Boolean* string, packed string types, or *PChar* > greater than compatible simple, *Boolean* string, packed string types, or *PChar* <= less than compatible simple, *Boolean* or equal to string, packed string types, or *PChar* >= greater than compatible simple, *Boolean* or equal to string, or packed string types, or *PChar* <= subset of compatible set types *Boolean* >= superset of compatible set types *Boolean* in member of left operand, any *Boolean* ordinal type *T;* right operand, set whose base is compatible with T

Comparing simple When the operands =, <>, <, >, >=, or <= are of simple types, they types must be compatible types; however, if one operand is of a real type, the other can be of an integer type.

*Chapter* 6, *Expressions*

*PChar* values. Note, however, that these relational tests assume that the two pointers being compared *point within the same character array,* and for that reason, the operators only compare the offset parts of the two pointer values. If the two character pointers point into different character arrays, the result is undefined.

If *A* and B are set operands, their comparisons produce these results:

- *A* = B is *True* only if *A* and B contain exactly the same members; otherwise, *A* **<>** B.
- *A* **<=** B is *True* only if every member of *A* is also a member of B.
- *A* **>=** B is *True* only if every member of B is also a member of *A.*
*Language Guide*

The @ operator is used in an address factor to compute the address of a variable, procedure, function, or method.

address factor **:--r----+I** variable reference procedure identifier function identifier

The @ operator returns the address of its operand, that is, it constructs a pointer value that points to the operand.

variable When applied to a variable reference, @ returns a pointer to the the resulting is controlled

|||variable.|The type of|pointer value|
|---|---|---|---|---|
||||$T|{$T-}|
|Special rules the @|apply to operator with|use|||
|procedural|variable.|For|||
|more|details,|see {$T|||
|"Procedural|types|in|||
|expressions"|on page|78.|||
|@|||@||

through the compiler directive: in the state (the default), *of* the result type is *Pointer.* In other words, the result is an untyped a pointer, which is compatible with all other pointer types. In the +} state, the type of the result is AT, where *Tis* the type of the variable reference. In other words, the result is of a type that is compatible only with other pointers to the type of the variable.

with a procedure, You can apply to a procedure, function, or method to produce a function, or method pointer to the routine's entry point. The type of the resulting pointer is always *Pointer,* regardless of the state of the **$T** compiler directive. In other words, the result is always an untyped pointer, which is compatible with all other pointer types.

When @ is applied to a method, the method must be specified through a *qualified-method identifier* (an object-type identifier, followed by a period, followed by a method identifier).

*Chapter* 6, *Expressions*

**calls**

|See "Method|activations"|on|
|---|---|---|
|page 40,|"Qualified-method||
|activations" "Procedural|on page|41, and· types" on page 44.|

A function call activates a function specified by a function identifier, a method designator, a qualified-method designator, or a procedural-type variable reference. The function call must have a list of actual parameters if the corresponding function declaration contains a list of formal parameters. Each parameter takes the place of the corresponding formal parameter according to parameter rules explained in Chapter 9, "Procedures and

107.

|functions,"|on page||
|---|---|---|
|function call|||
|function|identifier|actual parameter|
|method|designator||

list

|variable|reference||
|---|---|---|
|actual parameter|list|actual parameter|

#### -CD---r:1 TeD--

~---------~()~I-----~

actual parameter expression i-------r-- variable reference

##### Some examples of function calls follow:

Sum(A, 63) Maximum {147, J) Sin(X + Y) Eof (F) Volume (Radius, Height)

In the extended syntax {$X+} mode, function calls can be used as statements; that is, the result of a function call can be discarded.

#### Set constructors

A set constructor denotes a set-type value, and is formed by writing expressions within brackets ([D. Each expression denotes a value of the set.

*Language Guide*

set constructor-(Df--"lr---;:==========::;---,---' CD--

#### T! member group ~

L..----<Ol+I---.....
member group-l expression **I-** **r ---:::::::::----;:======::::;-,-+**

#### Lo-l expression f---1

The notation [] denotes the empty set, which is assignment- compatible with every set type. Any member group X .. Y denotes as set members all values in the range X .. Y. If X is greater than Y, then X .. Y doesn't denote any members and *[X .. Y]* denotes the empty set.

All expression values in member groups in a particular set constructor must be of the same ordinal type.

These

|are some|examples|of|set constructors:|
|---|---|---|---|
|[red, C,|green)|||
|[1, 5, 10|K mod 12,|23)||
|['A'||Chr(Digit|+ 48))|

.. .. 'Z', 'a' .. 'z',

**typecasts**

The type of an expression can be changed to another type through a value typecast.

value typecast-I type identifier r--cIH expression KD-

The expression type and the specified type must both be either ordinal types or pointer types. For ordinal types, the resulting value is obtained by converting the expression. The conversion may involve truncation or extension of the original value if the size of the specified type is different from that of the expression. In cases where the value is extended, the sign of the value is always preserved; that is, the value is sign-extended.

|See "Variable|typecasts"|on|
|---|---|---|
||page|57.|

The syntax of a value typecast is almost identical to that of a variable typecast. Value typecasts operate on values, however, not on variables, and therefore they can't particIpate in variable references; that is, a value typecast can't be followed by qualifiers. In particular, value typecasts can't appear on the left side of an assignment statement.

*Chapter* 6, *Expressions*

Char (48) Boolean(O) Color(2) Longint(@Buffer) BytePtr(Ptr($40, $49))

#### Procedural types in expressions

Usually, using a procedural variable in a statement or an expression calls the procedure or function stored in the variable. There is one exception: When the compiler sees a procedural variable on the left side of an assignment statement, it knows that the right side has to represent a procedural value. For example, consider the following program:

type IntFunc = function: Integer;

var F: IntFunc; N: Integer;

function ReadInt: Integer; far; var I: Integer; begin Read(I); ReadInt : = I; end;

begin F := ReadInt; { Assign procedural value } N := ReadInt; { Assign function result } end.

The first statement in the main program assigns the procedural value (address of) *Readlnt* to the procedural variable *F,* where the second statement calls *Readlnt* and assigns the returned value to

N. The distinction between getting the procedural value or calling the function is made by the type of the variable being assigned *(F* or N). Unfortunately, there are situations where the compiler can't determine the desired action from the context. For example, in the following statement there is no obvious way the compiler can
*Language Guide*

Pascal syntax, however, specifies that the occurrence of a function identifier in an expression denotes a call to that function, so the effect of the preceding statement is to call F and *Readlnt,* and then compare the returned values. To compare the procedural value in F to the procedural value of *Readlnt,* the following construct must be used:

##### if @F = @ReadInt then

Writeln('Equal');

When applied to a procedural variable or a procedure or function identifier, the address (@) operator prevents the compiler from calling the procedure, and at the same time converts the argument into a pointer. @F converts F into an untyped pointer variable that contains an address, and *@Readlnt* returns the address of *Readlnt;* the two pointer values can then be compared to determine if F currently refers to *Readlnt.*

The @ operator is often used when assigning an untyped pointer value to a procedural variable. Here is an example:

procedure SorneProc; begin

end;

var SornePtr: Pointer; begin

SornePtr := @SorneProc;

end.

To get the memory address of a procedural variable rather than the address stored in it, use a double address (@@) operator. For example, where @P means convert P into an untyped pointer variable, *@@P* means return the physical address of the variable P.

*Language Guide*

Ir-;:::::==::;--::::~TT---;:============:;--r- simple statement

A label is either a digit sequence in the range 0 to 9999 or an identifier.

There are two main types of statements: simple statements and structured statements.

##### Simple statements

A simple statement is a statement that doesn't contain any other statements.

simple statement assignment statement

*Chapter* 7, *Statements*

Assignment statements replace the current value of a variable with a new value specified by an expression. They can be used to set the return value of the function also.

assignment statement variable reference function identifier

|||||function|identifier|
|---|---|---|---|---|---|
|See|the section|"Type||||
|compatibility"|on page|47.||||

The expression must be assignment-compatible with the type of the variable or the type of the function result.

##### These statements:

|are examples|of|assignment|
|---|---|---|
|X := Y + Zi|||
|Done := (I|>= 1) and|(I < 100)i|
|Hue1 := [Blue,|SuCC(C)li||
|I := Sqr(J)|-I Ki||

*

Object-type

|The rules|of object-type|assignment|compatibility||allow an||
|---|---|---|---|---|---|---|
|instance|of object|type to be|assigned|an instance|of any|of its|
|descendant|types.|an assignment||constitutes|a projection|of|
|the descendant|onto|the space|spanned|its ancestor.|In the||
|example|code starting|on page|34, given|an instance|F of type||
|TField and|instance|Z of type|TZipField,|the assignment||F := Z|
|copies only|the fields|X, Y, Len,|and Name.||||
|Assigning|as instance|of an object|doesn't|initialize|the instance.||
|Referring|to the preceding|example,|the|assignment|F := Z|doesn't|
|mean that|a constructor|call for|F can be|omitted.|||

assignments an Such by

an

##### Procedure statements

|A procedure|statement|activates|a procedure|specified|by a|
|---|---|---|---|---|---|
|procedure|identifier,|a method|designator,|a qualified|method|
|designator,|or a procedural-type||variable|reference.|the|
|corresponding|procedure|declaration|contains|a list|of formal|
|parameters,|then the|procedure|statement|must have|a matching|
|list of actual|parameters|(parameters|listed|in definitions|are|
|formal parameters;|in|the calling|statement,|they are|actual|

If *See Chapter* 9, *"Procedures* *and functions. "*

*Language Guide*

**r------:nr-;:::============::::;-f-** actual parameter list method designator

variable reference

##### Some examples of procedure statements follow:

PrintHeadingi Transpose (A, N, *M)i* Find (Name, Address)i

A **goto** statement transfers program execution to the statement marked by the specified label. The syntax diagram of a **goto** statement follows:

goto statement ~

When using **goto** statements, observe the following rules:

- The label referenced by a **goto** statement must be in the same block as the **goto** statement. In other words, it's not possible to jump into or out of a procedure or function.
- Jumping into a structured statement from outside that structured statement (that is, jumping to a deeper level of nesting) can have undefined effects, although the compiler doesn't indicate an error. For example, you shouldn't jump into the middle of a **for** loop.
##### Structured statements

Structured statements are constructs composed of other statements that are to be executed in sequentially (compound and **with** statements), conditionally (conditional statements), or repeatedly (repetitive statements).

*Chapter* 7, *Statements*

structured statement-~-+l compound statement

The compound statement specifies that its component statements are to be executed in the same sequence as they are written. The component statements are treated as one statement, crucial in contexts where the Pascal syntax only allows one statement. **begin** and **end** bracket the statements, which are separated by semicolons.

compound statement

Here's an example of a compound statement:

begin Z := *Xi* X := *Yi* Y := *Zi* endi

Conditional

statements A conditional statement selects for execution a single one (or none) of its component statements.

conditional statement

If statements The syntax for an **if** statement reads like this:

The expression must yield a result of the standard type *Boolean.* If the expression produces the value *True,* then the statement following **then** is executed.

*Language Guide*

Y else Z := 1.5;

##### if P1 <> nil then

A P1 := P1.Father;

Case statements The **case** statement consists of an expression (the selector) and a list of statements, each prefixed with one or more constants (called *case constants)* or with the word **else.** The selector must be of a byte-sized or word-sized ordinal type, so string types and the integer type *Longint* are invalid selector types. All **case** constants must be unique and of an ordinal type compatible with the selector type.

case statement

case--r' constant I '~ constant ~ statement f--

*Chapter* 7, *Statements*

else part-®--I statement ~

The **case** statement executes the statement prefixed by a **case** constant equal to the value of the selector or a **case** range contain- ing the value of the selector. If no such **case** constant of the **case** range exists and an **else** part is present, the statement following **else** is executed. If there is no **else** part, execution continues with the next statement following the **if** statement.

##### These case

|are examples|of|statements:||
|---|---|---|---|
|case Operator|of|||
|Plus: X|:= X + Y;|||
|Minus: X|:= X -Y;|||
|Times: X end; case I of|:= X Y;|||
|0, 2, 4,|6, 8: Writeln('Even|||
|1, 3, 5,|7, 9: Writeln('Odd|||
|10 100: else|Writeln('Between|10 and|100');|
|Writeln('Negative end;|or|greater than|100');|

*

digit'); digit'); ..

Repetitive statements specify certain statements to be executed repeatedly.

repetitive statement

for statement

If the number of repetitions is known beforehand, the **for** statement is the appropriate construct. Otherwise, the **while** or **repeat** statement should be used.

The *Break* and *Continue* standard procedures can be used to control the flow of repetitive statements: *Break* terminates a repetitive statement, and *Continue* continues with the next iteration of a repetitive statement. For more details on these standard procedures, see Chapter I, "Library reference," in the *Programmer's Reference.*

*Language Guide*

~expressionf---

The expression must produce a result of type *Boolean.* The statements between the symbols **repeat** and **until** are executed in sequence until, at the end of a sequence, the expression yields *True.* The sequence is executed at least once because the expres- sion is evaluated *after* the execution of each sequence.

##### These repeat statements:

|are examples||of|
|---|---|---|
|repeat|||
|K := I mod I := J; J := K;|J;||
|J = repeat|0;||
|Write(/Enter|value|(0 9):|
|Readln(1)|;||
|(I >= while|0) and|(I <= 9);|

until

##### .. ');

until

While statements A statement contains an expression that controls the repeated execution of a statement (which can be a compound statement).

while statement ~ expression f---®--l statement **f--.**

The expression controlling the repetition must be of type *Boolean.* It is evaluated *before* the contained statement is executed. The contained statement is executed repeatedly as long as the expres- sion is *True.* If the expression is *False* at the beginning, the state-

|ment isn't executed|at all.||
|---|---|---|
||while||
|while Data[1]|<> X do I :=|I + 1;|

##### These are examples of statements:

*Chapter* 7, *statements*

0 do begin

|begin|||
|---|---|---|
|Odd (I)|then Z|:= Z X;|
|I := I div|2;||
|X := Sqr(X);|||
|end;|||
|while not 'Eof(1nFile)||do|
|begin|||
|Readln(1nFile,|Line);||
|Process (Line)|;||
|end;|||
|for|||

if *

For statements The statement causes a statement to be repeatedly executed while a progression of values is assigned to a control variable. Such a statement can be a compound statement.

for statement

||||control variable|variable|
|---|---|---|---|---|
||||initial value final value|expression expression|
|See|Chapter|8 for|||
|discussion|locality|and scope.|||

#### -I identifier ~ -I ~ -I ~

a The control variable must be a variable identifier (without any *of* qualifier) that is local in scope to the block containing the **for** statement. The control variable must be of an ordinal type. The initial and final values must be of a type assignment-compatible with the ordinal type.

When a **for** statement is entered, the initial and final values are determined once for the remainder of the execution of the **for** statement.

The statement contained by the **for** statement is executed once for every value in the range *initial value* to *final value.* The control vari- able always starts off at *initial value.* When a **for** statement uses to, the value of the control variable is incremented by one for each repetition. If *initial value* is greater than *final value,* the contained statement isn't executed. When a **for** statement uses **downto,** the value of the control variable is decremented by one for each repetition. If *initial value* value is less than *final value,* the contained statement isn't executed.

*Language Guide*

##### If the contained statement alters the value of the control variable,

##### your results will probably not be what you expect. After a for

**statement is executed, the value of the control variable value is undefined, unless execution of the for statement was interrupted**

by a **goto from the for statement.**

##### With these restrictions in mind, the for statement

**for** V := ExprI **to** Expr2 **do** Body;

**is**

|equivalent|to||
|---|---|---|
|begin|||
|TempI :=|ExprI;||
|Temp2 :=|Expr2;||
|TempI begin|<= Temp2|then|
|V := Body;|TempI;||
|while begin|V <> Temp2|do|
|V : Body; end; end; end;|= Succ (V)|;|

**if**

##### and the for statement

**for** V := ExprI **downto** Expr2 **do** Body;

**is**

|equivalent|to||
|---|---|---|
|begin|||
|TempI :=|ExprI;||
|Temp2 :=|Expr2;||
|TempI begin|>= Temp2|then|
|V := Body;|TempI;||
|while begin|V <> Temp2|do|
|V := Body; end; end; end;|Pred(V);||

**if**

**7, *Statements***

where *Templ* and *Temp2* are auxiliary variables of the host type of the variable *V* and don't occur elsewhere in the program.

These

|are examples|of|for statements:|
|---|---|---|
|I := 2 to|63 do||
|Data[I] Max := Data[I]|> Max then||
|I := 1 to|10 do||
|for J := 1 begin X := 0;|to 10 do||
|for K :=|1 to 10|do|
|X := X Ma t [J] end;|+ Mat1[I, : = X;|K] Mat2[K,|
|C := Red|to Blue|do Check(C);|

for if

for

* J];
I,

for

The **with** statement is shorthand for referencing the fields of a record, and the fields and methods of an object. Within a **with** statement, the fields of one or more specific record variables can be referenced using their field identifiers only. The syntax of a **with** statement follows:

record or object ~I L-------.. variable reference ~ variable reference_ ~

Given this type declaration,

type TDate = record Day : Integer; Month: Integer; Year : Integer; end;

var OrderDate: TDate;

*Language Guide*

here is an example of a statement:

|||with|
|---|---|---|
|with OrderDate|do||
|Month|12 then||
|begin|||
|Month|:= 1;||
|Year|:= Year +|1|
|end|||
|else|||
|Month|:= Month|+ 1;|

if =

|This is equivalent|to||
|---|---|---|
|OrderDate.Month begin|12 then||
|OrderDate.Month|:= 1;||
|OrderDate.Year end|:= TDate.Year|+ 1|
|OrderDate.Month with|:= TDate.Month|+ 1;|

if =

else

Within a statement, each variable reference is first checked to see if it can be interpreted as a field of the record. If so, it's always interpreted as such, even if a variable with the same name is also accessible. Suppose the following declarations have been made:

type TPoint = record *X,* Y: Integer; end; var X: TPoint; Y: Integer;

In this case, both X and Y can refer to a variable or to a field of the record. In the statement

with X do begin X := 10; Y := 25; end;

the X between **with** and **do** refers to the variable of type *TPoint,* but in the compound statement, X and Y refer to X.X and X. Y.

7, *Statements*

S;

is equivalent to

with Vl do with V2 do

with Vn do S;

In both case?, if *Vn* is a field of both *Vl* and *V2,* it's interpreted as *V2.Vn,* not *Vl.Vn.*

If the selection of a record variable involves indexing an array or dereferencing a pointer, these actions are executed once before the component statement is executed.

*Language Guide*

##### A p T E R

|locality, of|declarations, and a|and scope which are written and statements. Each block is part function declaration, a method or unit. All identifiers and labels part are local to the block.|8 of a|
|---|---|---|---|
|of H H r-- r--|any part ~|block follows this format: ~I statement part ~ label declaration part I constant declaration part type declaration part variable declaration part I procedure/function declaration part I--||

#### Blocks,

A *block* is made up combined in any order, procedure declaration, declaration, or a program declared in the declaration

#### Blocks

##### The overall syntax

block-l declaration

declaration part

Labels that mark statements in the corresponding statement part are declared in the *label declaration part.* Each label must mark only one statement.

*Chapter* 8, *Blocks, locality, and scope*

declaration part

A label must be an identifier or a digit sequence in the range a to

9999. The *constant declaration part* consists of constant declarations local to the block. constant

|declaration|part||
|---|---|---|
|>--:t---,r--+!|constant typed|declaration constant|

#### .-----------,

**i----r--"T"'"+** declaration

The *type declaration part* includes all type declarations local to the block.

type declaration part-~ type declaration I--r

The *variable declaration part* is composed of variable declarations local to the block.

variable declaration part-@>-rl variable declaration l-r

The *procedure and function declaration part* is made up of procedure local to the block.

|and function|declarations||
|---|---|---|
|procedure/function||declaration|
|L...-r---r--+I|procedure function constructor destructor|declaration declaration declaration declaration|

part

The *statement part* defines the statements or algorithmic actions to be executed by the block.

statement part-l compound statement r

*Language Guide*

**of scope**

The presence of an identifier or label in a declaration defines the identifier or label. Each time the identifier or label occurs again, it must be within the *scope* of this declaration.

##### Block scope

The scope of an identifier or label declared in a label, constant, type, variable, procedure, or function declaration stretches from the point of declaration to the end of the current block, and includes all blocks enclosed by the current block.

An identifier or label declared in an outer block can be *redeclared* in an inner block enclosed by the outer block. Before the point of declaration in the inner block, and after the end of the inner block, the identifier or label represents the entity declared in the outer block.

Start

|program|Outer;|{|of outer scope|}|
|---|---|---|---|---|
|type|||||
|I Integer; var||{define|I as type|Integer}|
|T: I;||{define|T as an Integer|variable|
|procedure type|Inner;||of inner scope|}|
|T = I; var||redefine|T as type|Integer|
|T; begin||{redefine|I as an|Integer variable|
|I : =|1;||||
|end; begin||{End of|inner scope|}|
|T :|1;||||
|end.||{End of|outer scope|}|

=

}

Start

I:

=

##### Record scope

The scope of a field identifier declared in a record-type definition extends from the point of declaration to the end of the record-type definition. Also, the scope of field identifiers includes field desig- *See "Record types" on*nators and **with** statements that operate on variable references of *page* 32. the given record type.

*Chapter* 8, *Blocks, locality, and scope*

##### Object scope

The scope of a component identifier declared in an object-type definition extends from the point of declaration to the end of the object-type definition, and extends over all descendants of the *See "Object*object type and the blocks of all method declarations of the object

|types"|on|
|---|---|
|page|33.|

type. The scope of component identifiers includes field designators and with statements that operate on variable references of the given object type.

##### Unit scope

The scope of identifiers declared in the interface section of a unit follow the rules of block scope, and extends over all *clients* of the unit. In other words, programs or units containing uses clauses have access to the identifiers belonging to the interface parts of the units in those uses clauses.

Each unit in a uses clause imposes a new scope that encloses the remaining units used and the program or unit containing the uses clause. The first unit in a uses clause represents the outermost scope, and the last unit represents the innermost scope. This implies that if two or more units declare the same identifier, an unqualified reference to the identifier selects the instance declared by the last unit in the uses clause. But by writing a qualified identifier (a unit identifier, followed by a period, followed by the identifier), every instance of the identifier can be selected.

The identifiers of Turbo Pascal's predefined constants, types, variables, procedures, and functions act as if they were declared in a block enclosing all used units and the entire program. In fact, these standard objects are defined in a unit called *System,* which is used by any program or unit before the units named in the uses clause. This means that any unit or program can redeclare the standard identifiers, but a specific reference can still be made through a qualified identifier, for example, *System.Integer* or *System. Writeln.*

*Language Guide*

##### A p T E R

#### Procedures and functions

*See Chapter* 8, *"Blocks,*Procedures and functions let you nest additional blocks in the *locality, and scope, II for* a main program block. Each procedure or function declaration has a *definition of* a *block.* heading followed by a block. A procedure is activated by a procedure statement; a function is activated by the evaluation of an expression that contains its call and returns a value to that expression.

|Standard|procedures|and|
|---|---|---|
|functions|are those|that are|
|defined|in Turbo System|Pascal's unit.|

This chapter discusses the different types of procedure and function declarations and their parameters.

#### Procedure declarations

A *procedure declaration* associates an identifier with a block as a procedure; that procedure can then be activated by a procedure statement.

procedure declaration

#### Y procedure heading f--O-l subroutine block ~

procedure heading

formal parameter list

*Chapter* 9, *Procedures and functions*

procedure body

The procedure heading names the procedure's identifier and specifies the formal parameters (if any). *"Parameters" on* *page 107.* A procedure is activated by a procedure statement, which states the procedure's identifier and actual parameters, if any. The statements to be executed on activation are noted in the statement part of the procedure's block. If the procedure's identifier is used in a procedure statement within the procedure's block, the procedure is executed recursively (it calls itself while executing).

Here's an example of a procedure declaration:

procedure NumString(N: Integer; var S: string); var V: Integer; begin V := Abs (N);

|V := Abs|(N);|||
|---|---|---|---|
|S-",.||||
|repeat||||
|S := Chr(N|mod|10 + Ord('O'))|+ S;|
|N := N|div 10;|||
|N|0;|||
|N < 0|then|||
|S end;|+ S;|||

. .-

until = if .-'-'

##### Near and far

**declarations** Turbo Pascal supports two procedure and function call models: near and far. In terms of code size and execution speed, the near

|Near|and far calls|are|
|---|---|---|
|described|in Chapter "Control|20, issues. "|

call model is the more efficient, but **near** procedures and functions can only be called from within the module they are declared in. On the other hand, **far** procedures and functions can be called from any module, but the code for a far call is slightly less efficient.

The compiler automatically selects the correct call model based on a procedure's or function's declaration: Procedures and functions declared in the **interface** part of a unit use the far call model-

*Language Guide*

they can be called from other modules. Procedures and functions declared in a program or in the **implementation** part of a unit use the near call model-they can only be called from within that program or unit.

For some purposes, a procedure or function may be required to use the far call model. For example, if a procedure or function is to be assigned to a procedural variable, it has to use the far call model. The **$F** compiler directive can be used to override the compiler's automatic call model selection. Procedures and functions compiled in the {$F+} state always use the far call model; in the {$F-} state, the compiler automatically selects the correct model. The default state is {$F-}.

To force a specific call model, a procedure or function declaration can optionally specify a **near or far** directive before the block-if such a directive is present, it overrides the setting of the **$F** compiler directive as well as the compiler's automatic call model selection.

|Optionally,|a procedure|declaration|can specify|an interrupt|
|---|---|---|---|---|
|directive|before the|block; the|is|then considered|
|interrupt|procedure.|For now, note|that interrupt|procedures|
|be called|from procedure|statements,|and that|every interrupt|
|procedure|must specify|a parameter|list like|the following:|

procedure an can't

|interrupt||procedure|MyInt(Flags,|IP, AX, BX,|DX,|SI, DI, DS,|ES,|
|---|---|---|---|---|---|---|---|
|on page|243.|BP: Word);||||||

es, ex, *procedures"* interrupt;

The parameter list doesn't have to match this syntax perfectly; it can be shorter and use different names, but the register contents are passed in the order listed .above.

Forward

declarations A procedure or function declaration that specifies the directive **forward** instead of a block is a **forward** declaration. Somewhere after this declaration, the procedure must be defined by a *defining* *declaration.* The defining declaration can omit the formal parameter list and the function result, or it can optionally repeat it. In the latter case, the defining declaration's heading must match exactly the order, types, and names of parameters, and the type of the function result, if any.

*Chapter* 9, *Procedures and functions*

The **forward** declaration and the defining declaration must appear in the same procedure and function declaration part. Other procedures and functions can be declared between them, and they can call the forward-declared procedure. Therefore, mutual recursion is possible.

The **forward** declaration and the defining declaration constitute a complete procedure or function declaration. The procedure or function is considered declared at the **forward** declaration.

This is an example of a **forward** declaration:

procedure Walter(M, N: Integer); forward;

procedure Clara(X, Y: Real); begin

Walter(4, 5);

end;

procedure Walter; begin

Clara (8.3, 2.4);

end;

A procedure's or function's defining declaration can be an **external** or **assembler** declaration; however, it can't be a **near, far,** **interrupt, or inline** declaration or another **forward** declaration.

##### External

**declarations External** declarations let you interface with separately compiled procedures and functions written in assembly language. The *For further details on linking* *with assembly language, see*external code must be linked with the Pascal program or unit *Chapter 23.* through **{$L** *filename}* directives.

##### Examples of external procedure declarations follow:

procedure MoveWord(var Source, Dest; Count: Word); external; procedure MoveLong(var Source, Dest; Count: Word); external;

procedure FillWord(var Dest; Data: Integer; Count: Word); external; procedure FillLong(var Dest; Data: Longint; Count: Word); external;

{$L BLOCK.OBJ}

*Language Guide*

With **assembler** declarations, you can write entire procedures and functions in inline assembly language.

||For more details|on|||
|---|---|---|---|---|
|assembler|procedures|and|asm block||
|functions,|see Chapter|22.||asm statement|

declaration part

##### Inline

**declarations** The **inline** directive enables you to write machine code instruc- tions in place of a block of Pascal code.

inline directive-l inline statement ~

*See the syntax of an inline*When a normal procedure or function is called, the compiler *statement on page 284.* generates code that pushes the procedure's or function's parameters onto the stack and then generates a CALL instruction to call the procedure or function. When you call an **inline** procedure or function, the compiler generates code from the **inline** directive instead of the CALL. Therefore, an **inline** procedure or function is expanded every time you refer to it, just like a macro in assembly language.

|Here's a|short example|two||
|---|---|---|---|
|procedure|Disablelnterruptsi|inline($FA)i|{eLI}|
|procedure|Enablelnterruptsi|inline($FB)i|{STI}|

##### of inline procedures:

#### Function declarations

A function declaration defines a block that computes and returns a value.

function declaration

#### L-I function heading ~I subroutine block 1-0-

function heading

#### .----,

*Chapter* 9, *Procedures and functions*

*can't* a

|A function|return||
|---|---|---|
|structured|type or a|result type|
|procedural|type.||

The function heading specifies the identifier for the function, the formal parameters (if any), and the function result type.

A function is activated by the evaluation of a function call. The function call gives the function's identifier and actual parameters, if any, required by the function. A function call appears as an operand in an expression. When the expression is evaluated, the function is executed, and the value of the operand becomes the value returned by the function.

The statement part of the function's block specifies the statements to be executed upon activation of the function. The block should contain at least one assignment statement that assigns a value to the function identifier. The result of the function is the last value assigned. If no such assignment statement exists or if it isn't executed, the value returned by the function is undefined.

If the function's identifier is used in a function call within the function's block, the function is executed recursively.

##### Following are examples of function declarations:

function Max(A: Vector; N: Integer): Extended; var. X: Extended; I: Integer; begin X := A[l]; for I := 2 to N do if X < A[I] then X := A[I]; Max := X; end;

function Power(X: Extended; Y: Integer): Extended; var Z: Extended; I: Integer; begin Z := 1.0; I := Y; while I > 0 do begin if Odd (I) then Z := Z * X; I := I div 2; X := Sqr(X); end;

*Language Guide*

:= *Zj* *endj*

Like procedures, functions can be declared as

||||near, far,|forward,|
|---|---|---|---|---|
|external,|assembler,|or inline;|||

##### but interrupt functions aren't

allowed.

#### Method declarations

|See page|37 for more|about|
|---|---|---|
|declaring|methods|in objects.|

The declaration of a method within an object type corresponds to a **forward** declaration of that method. Therefore, somewhere after the object-type declaration and within the same scope as the object-type declaration, the method must be implemented by a defining declaration.

For procedure and function methods, the defining declaration takes the form of a normal procedure or function, but the proce- dure or function identifier is a *qualified-method identifier.* This is an object-type identifier followed by a period C.) and then by a method identifier.

For constructor methods and destructor methods, the defining declaration takes the form of a procedure method declaration, except that the **procedure** reserved word is replaced by a **con-** **structor or destructor** reserved word.

Optionally, a method's defining declaration can repeat the formal parameter list of the method heading in the object type. If it does, the defining declaration's method heading must match exactly the order, types, and names of the parameters, and the type of the function result, if any.

In the defining declaration of a method, there is always an impli- cit parameter with the identifier *Self,* corresponding to a formal variable parameter that possesses the object type. In the method block, *Self* represents the instance whose method component was designated to activate the method. Therefore, any changes made to the values of the fields of *Self* are reflected in the instance.

The scope of a component identifier in an object type extends over any procedure, function, constructor, or destructor block that implements a method of the object type. The effect is the same as if the entire method block was embedded in a **with** statement of the form

with Self do begin ... end

*Chapter* 9, *Procedures and functions*

For this reason, the spellings of component identifiers, formal method parameters, *Self,* and any identifiers introduced in a method implementation must be unique.

Here are some examples of method implementations:

*the object-type* procedure TRectangle.Intersect(var R: TRectangle); *dec/arations of these* begin *examples on page 34.* if A.X < R.A.X then A.X := R.A.X; if A.Y < R.A.Y then A.Y := R.A.Y; if B.X > R.B.X then B.X := R.B.X; if B.Y > R.B.Y then B.Y := R.B.Y; if (A.X >= B.X) or (A.Y >= B.Y) then Init(O, 0, 0, 0); end;

procedure TField.Display; begin GotoXY(X, Y); A Write (Name, ' " GetStr); end;

function TNumField.PutStr(S: String): Boolean; var E: Integer; begin Val(S, Value, E); PutStr .-(E = 0) and (Value >= Min) and (Value <= Max); end;

Constructors and *Constructors* and *destructors* are specialized forms of methods. destructors Used in connection with the extended syntax of the *New* and *Dispose* standard procedures, constructors and destructors have the ability to allocate and deallocate dynamic objects. In addition, construCtors have the ability to perform the required initialization of objects that contain virtual methods. Like other methods, con- structors and destructors can be inherited, and an object can have any number of constructors and destructors.

Constructors are used to initialize newly created objects. Usually, the initialization is based on values passed as parameters to the constructor. Constructors can't be virtual because the virtual- method dispatch-mechanism depends on a constructor first having initialized the object.

constructor declaration

#### Y constructor heading ~ subroutine block ~

*Language Guide*

**formal parameter list**

##### Here are some examples of constructors:

**constructor** TField.Copy(var F: TField); **begin** Self := F; **end;**

**constructor** TField.Init(FX, FY, FLen: Integer; FName: String); **begin** X := FX; Y := FY; Len := FLen; GetMem(Name, Length (FName) + 1); Name" := FName; **end;**

**constructor** TStrField.Init(FX, FY, FLen: Integer; FName: String); **begin** **inherited** Init(FX, FY, FLen, FName); GetMem(Value, Len); Value" := "; **end;**

##### The first action of a constructor of a descendant type, such as the

**preceding *TStrField.lnit,* is almost always to call its immediate ancestor's corresponding constructor to initialize the inherited**

##### fields of the object. Having done that, the constructor then ini-

##### tializes the fields of the object that were introduced in the descendant.

**Destructors are the counterparts of constructors, and are used to** **clean up objects after their use. Typically, the cleanup consists of** **disposing of any pointer fields that were allocated by the object.**

**destructor declaration**

#### Y destructor heading ~ subroutine block ~

***Chapter* 9, *Procedures and functions***

destructor heading

formal parameter list

some

|Here are|examples|of|destructors:|
|---|---|---|---|
|destructor begin|TField.Done;|||
|FreeMem(Name, end; destructor begin|Length TStrField.Done;|(Name|+ 1);|
|FreeMem(Value,|Len);|||
|inherited end;|Done;|||

A )

A destructor of a descendant type, such as the preceding *TStrField.Done,* usually disposes of the pointer fields introduced in the descendant, and then, as its last action, calls the correspond- ing destructor of its immediate ancestor to dispose of any inher- ited pointer fields of the object.

Constructor-error Turbo Pascal allows you to install a heap-error function through recovery the *HeapError* variable in the *System* unit; see Chapter 19. This functionality affects the way object-type constructors work.

By default, when there isn't enough memory to allocate a dynamic instance of an object type, a constructor call using the extended syntax of the *New* standard procedure generates run- time error 203. If you install a heap-error function that returns 1 rather than the standard function result of 0, a constructor call through *New* will return **nil** when it can't complete the request (instead of aborting the program).

The code that performs allocation and virtual method table (VMT) field initialization of a dynamic instance is part of a constructor's entry sequence: When control arrives at the **begin** of the construc- tor's statement part, the instance will have been allocated and initialized already. If allocation fails and the heap-error function returns 1, the constructor skips execution of the statement part and returns a **nil** pointer. The pointer specified in the *New* construct that called the constructor is set to **nil.**

*Language Guide*

Once control arrives at the **begin** of a constructor's statement part, the object-type instance is guaranteed to have been allocated and initialized successfully. The constructor itself, however, might attempt to allocate dynamic variables to initialize pointer fields in the instance and, in turn, these allocations might fail. If that happens, a well-behaved constructor should reverse any successful allocations and deallocate the object-type instance so that the net result becomes a **nil** pointer. To make such backing out possible, Turbo Pascal implements the *Fail* standard procedure that takes no parameters and can be called only from within a constructor. A call to *Fail* causes a constructor to deallo- cate the dynamic instance that was allocated upon entry to the constructor and causes the return of a **nil** pointer to indicate its failure.

When dynamic instances are allocated through the extended syntax of *New,* a resulting value of **nil** in the specified pointer variable indicates that the operation failed. Unfortunately, there is no such pointer variable to inspect after the construction of a static instance or when an inherited constructor is called. Instead, Turbo Pascal allows a constructor to be used as a Boolean func- tion in an expression: A return value of *True* indicates success, and a return value of *False* indicates failure due to a call to *Fail* within the constructor.

On disk you'll find two programs, NORECVER.P AS and RECOVER.P AS. Both implement two simple object types that contain pointers. The NORECVER version of the program does not implement constructor-error recovery.

RECOVER.P AS demonstrates how the program can be rewritten to implement error recovery. Notice how the corresponding de- structors in *Base.Init* and *Derived.lnit* are used to reverse any successful allocations before *Fail* is called to finally fail the operation. Also notice that in *Derived.Init,* the call to *Base.lnit* is coded within an expression so that the success of the inherited constructor can be tested.

The declaration of a procedure or function specifies a *formal* *parameter list.* Each parameter declared in a formal parameter list is local to the procedure or function being declared. Your

*Chapter* 9, *Procedures and functions*

program can refer to it by its identifier in the block associated wi th the procedure or function.

formal parameter list-cD-rl parameter .declaration r-rw-

~------~CD~·------~

parameter declaration ,...--------,

parameter type

There are four kinds of parameters: *value, constant, variable,* and *untyped.* These are characterized as follows:

- A parameter group without a preceding **var** and followed by a type is a list of value parameters.
- A parameter group preceded by **const** and followed by a type is a list of constant parameters.
- A parameter group preceded by **var** and followed by a type is a list of variable parameters.
- A parameter group preceded by **var or const** and *not* followed by a type is a list of untyped parameters. String and array type parameters can be *open parameters.* A variable parameter declared using the *OpenString* identifier, or using the **string** keyword in the **{$P+}** state, is an *open-string* *parameter.* A value, constant, or variable parameter declared using the syntax **array of** *T* is an *open-array parameter.*
##### Value parameters

A formal value parameter acts like a variable local to the proce- dure or function, except it gets its initial value from the corres- ponding actual parameter upon activation of the procedure or function. Changes made to a formal value parameter don't affect the value of the actual parameter.

A value parameter's corresponding actual parameter in a proce- dure statement or function call must be an expression, and its value must not be of file type or of any structured type that contains a file type.

The actual parameter must be assignment-compatible with the type of the formal value parameter. If the parameter type is **string,** then the formal parameter is given a size attribute of 255.

*Language Guide*

A constant parameter's corresponding actual parameter in a procedure statement or function must follow the same rules as an actual value parameter.

In cases where a formal parameter never changes its value during the execution of a procedure or function, a constant parameter should be used instead of a value parameter. Constant parameters allow the implementor of a procedure or function to protect against accidental assignments to a formal parameter. Also, for structured-and string-type parameters, the compiler can generate more efficient code when constant parameters are used instead of value parameters.

Variable

parameters A variable parameter is used when a value must be passed from a procedure or function to the caller. The corresponding actual parameter in a procedure statement or function call must be a variable reference. The formal variable parameter represents the actual variable during the activation of the procedure or function, so any changes to the value of the formal variable parameter are reflected in the actual parameter.

*File types can* be *passed*Within the procedure or function, any reference to the formal *only* as *variable parameters.* variable parameter accesses the actual parameter itself. The type of the actual parameter must be identical to the type of the formal variable parameter (you can bypass this restriction through untyped parameters).

|For more|information|on|$P|
|---|---|---|---|
|open-string|parameters, page|see 717.|string|

The compiler directive controls the meaning of a variable parameter declared using the **string** keyword. In the default {$P-} state, corresponds to a string type with a size attribute of

255. In the {$P+} state, **string** indicates that the parameter is an open-string parameter.
*Chapter* 9, *Procedures and functions*

If referencing an actual variable parameter involves indexing an array or finding the object of a pointer, these actions are executed before the activation of the procedure or function.

The rules of object-type assignment compatibility also apply to object-type variable parameters: For a formal parameter of type *Tl,* the actual parameter might be of type *T2* if *T2* is in the domain of *Tl.* For example, given the object-type declarations found on page 34, the *TField.Copy* method might be passed an instance of *TField, TStrField, TNumField, TZipField,* or any other instance of a descendant of *TField.*

##### Untyped

**parameters** When a formal parameter is an untyped parameter, the corres- ponding actual parameter can be any variable or constant reference, regardless of its type. An untyped parameter declared using the **var** keyword can be modified, whereas an untyped parameter declared using the **const** keyword is read-only.

Within the procedure or function, the untyped parameter is typeless; that is, it is incompatible with variables of all other types, unless it is given a specific type through a variable typecast.

This is an example of untyped parameters:

function Equal (var Source, Dest; Size: Word): Boolean; type TBytes = array[O .. 65534] of Byte; var N: Word; begin N := 0; while (N < Size) and (TBytes(Dest) [N] = TBytes(Source) [N]) do Inc (N); Equal := N = Size; end;

This function can be used to compare any two variables of any

|size. For instance,|given|the declarations|
|---|---|---|
|type|||
|TVector||lO] of Integer;|
|TPoint|record||
|X, end;|Y: Integer;||

##### = array[l ..

=

*Language Guide*

var Vecl, Vec2: TVector; N: Integer; P: TPoint;

|the function|then calls|||
|---|---|---|---|
|Equal (Vecl,|Vec2, SizeOf(TVector))|||
|Equal (Vecl,|Vec2, SizeOf(Integer)||N)|
|Equal (Vec[l]|, Vecl[6],|SizeOf(Integer)|5)|
|Equal (Vecl[l]|, P, 4)|||

* *

which compares *Vec1* to *Vee2,* the first N components of *Veel* to the first N components of *Vee2,* the first five components of *Vec1* to the last five components of *Vec1,* and *Veel[l]* to P.X and *Vec1[2]* *toP.Y.*

While untyped parameters give you greater flexibility, they can be riskier to use. The compiler can't verify that operations on untyped variables are valid.

**parameters**

Open parameters allow strings and arrays of varying sizes to be passed to the same procedure or function.

Open-string Open-string parameters can be declared in two ways: parameters

- Using the *OpenString* identifier
- Using the **string** keyword in the **{$P+}** state The *OpenString* identifier is declared in the *System* unit. It denotes a special string type that can only be used in the declaration of string parameters. For reasons of backward compatibility, *OpenString* isn't a reserved word-this means that *OpenString* can be redeclared as a user-defined identifier. When backward compatibility isn't an issue, a **{$P+}** compiler directive can be used to change the meaning of the **string** keyword. In the **{$P+}** state, a variable declared using the **string** keyword is an open-string parameter. For an open-string parameter, the actual parameter can be a variable of any string type. Within the procedure or function, the size attribute (maximum length) of the formal parameter will be the same as that of the actual parameter.
*Chapter* 9, *Procedures and functions*

[20]; begin

|begin|||
|---|---|---|
|Assign8tr|(81);|'0123456789'|
|Assign8tr(82);||82 = '0123456789ABCDEF'|
|end;|||

81= }

|Within|Assign5tr,|the maximum|length|of the 5 parameter|is|the|
|---|---|---|---|---|---|---|
|same as|that of the|actual parameter.|Therefore,|in|the first call|to|
|Assign5tr,|the assignment|to|the 5 parameter|truncates|the string||
|because|the declared|maximum|length|of 51 is 10.|||
|When applied|to|open-string|parameter,|the Low|standard||
|function|returns zero,|the High|standard|function returns|the||
|declared|maximum|length of|the actual|parameter,|and the|5izeO!|
|function|returns the|size of the|actual parameter.||||
|In the next|example,|the Fill5tring|procedure|fills a|string to|its|
|maximum|length|with a given|character.|Notice the|use of the||
|High standard|function|to obtain|the maximum|length|of an||

an

|open-string|parameter.|||||
|---|---|---|---|---|---|
|procedure begin|Fil18tring(var||8: Open8tring;|Ch:|Char);|
|S[O]|:= Chr(High(S));|||Set||
|FillChar(8[1], end;||High(8), string|Ch);|Set|characters|

string length} string

Value and constant parameters declared using the *Open5tring* identifier or the keyword in the **{$P+}** state aren't open- string parameters. Instead, such parameters behave as if they were declared using a string type with a maximum length of 255,

*Language Guide*

last

||element|in the|actual array|parameter,|and the|
|---|---|---|---|---|---|
|SizeD! function|returns|the size|of the actual|array parameter.||
|The Clear|procedure|in the next|example|assigns zero|to each|
|element of|an array|of Real, and|the Sum|function computes|the|
|sum of all|elements|in array|of Real. Because|the|A parameter|
|in both cases|is an open-array||parameter,|the subroutines|can|
|operate on|any array|with|element type|of Real.||

an

an

*Chapter* 9, *Procedures and functions*

||0 to High(A)|do A[I]|:= 0;|
|---|---|---|---|
|end;||||
|function var I: Word; S: Real; begin S : 0;|Sum(const A:|array of Real):|Real;|
|for I :=|0 to High(A)|do S :=|S + A[I];|
|Sum := end;|S;|||

=

When the element type of an open-array parameter is *Char,* the actual parameter may be a string constant. For example, given the

|procedure|declaration,|||
|---|---|---|---|
|procedure var Integer; begin|PrintStr(const|S: array|of Char);|
|for I :=|0 to High(S)|do||
|SrI] end;|<> #0 then|Write(S[I])|Break;|

I:

if else

##### the following are valid procedure statements:

PrintStr('Hello world') i PrintStr (' A');

When passed as an open-character array, an empty string is converted to a string with one element containing a NULL character, so the statement *PrintStr(")* is identical to the statement *PrintStr(#O).*

#### Dynamic object-type variables

The *New* and *Dispose* standard procedures allow a constructor call or destructor call as a second parameter for allocating or disposing of a dynamic object-type variable. This is the syntax:

*Language Guide*

P is a pointer variable, pointing to an object type, and *Construct* and *Destruct* are calls to constructors and destructors of that object type. For *New,* the effect of the extended syntax is the same as executing

New(P); P".Construct;

And for *Dispose,* the effect of the extended syntax is the same as executing

P".Destruct; Dispose (P);

Without the extended syntax, you would frequently have to call *New* followed by a constructor call or call a destructor followed by a call to *Dispose.* The extended syntax improves readability and generates shorter and more efficient code.

The following illustrates the use of the extended *New* and *Dispose* syntax:

var SP: PStrField; ZP: PZipField; begin New(SP, Init(l, 1, 25, 'Firstname'));

|New(SP,|1, 25,|'Firstname'));||
|---|---|---|---|
|New(ZP, SP".Edit; ZP".Edit; Dispose(ZP, Dispose(SP, end;|(1, 2, 5, Done); Done);|code',|0, 99999));|

##### Init 'zip

You can also use *New* as *afunction* that allocates and returns a dynamic variable of a specified type:

New(T)

or

New(T, Construct)

*Chapter* 9, *Procedures and functions*

0, 99999));

A

|WriteLn(F1|.GetStr);|{Calls TStrField.GetStr||}|
|---|---|---|---|---|
|WriteLn(F2|.GetStr);|{Calls TzipField.GetStr||}|
|Dispose(F2,|Done);|{Calls|TField.Done|}|
|Dispose(Fl, end;|Done);|{Calls|TStrField.Done|}|

A

Notice that even though *F1* and *F2* are of type *PField,* the extended-pointer assignment-compatibility rules allow *F1* and *F2* to be assigned a pointer to any descendant of *TField.* Because *GetStr* and *Done* are virtual methods, the virtual-method dispatch-mechanism correctly calls *TStrField.GetStr,* *TZipField.GetStr, TField.Done,* and *TStrField.Done,* respectively.

*Language Guide*

##### A p T E R

#### 10 Programs and units

A Turbo Pascal program consists of a program heading, an optional **uses** clause, and a block. program LQr-p-r-og-ra-m-h-e-ad-in-g---'~ t Ii ,~ L_~========~~::::'--.J--i uses clause ~

The program heading specifies the program's name and its parameters.

||program|parameters|
|---|---|---|
|program parameters|list||

#### -I identifier I-

If a program heading is present, the compiler ignores it.

**clause**

The **uses** clause identifies all units used by the program.

uses clause

*Chapter 70, Programs and units*

##### System unit is always used automatically. System implements

all low-level, run-time procedures and functions to support such features as file input and output (I/O), string handling, floating point, dynamic memory allocation, and others.

Apart from *System,* Turbo Pascal implements many standard units, such as *Dos* and *Crt.* These aren't used automatically; you must include them in your **uses** clause. For example,

uses Dos, Crt; { Can now use Dos and Crt

The order of the units listed in the **uses** clause determines the order of their initialization (see "The initialization part" on page 120).

To find the unit file containing a compiled unit, the compiler truncates the unit name listed in the **uses** clause to the first eight characters and adds the file extension .TPU. For example, a unit named *MathFunctions* will be stored in a file called MATHFUNC.TPU. Even though the file name is truncated, a **uses** clause must still specify the full unit identifier.

|Units|are the basis|of modular|programming|in|Turbo Pascal.|
|---|---|---|---|---|---|
|They're|used to|create libraries|that|you can include|in various|
|programs|without|making|the source|code available,|and to|
|divide|large programs|into|logically|related modules.||

The unit heading specifies the unit's name.

unit heading-@D---l unit identifier **r--**

The unit name is used when referring to the unit in a **uses** clause. The name must be unique: Two units with the same name can't be used at the same time.

The name of a unit's source file and binary file must be the same as the unit identifier, truncated to the first eight characters. If this

*Language Guide*

isn't the case, the compiler can't find the source and/or binary file when compiling a program or unit that uses the unit.

The interface part declares constants, types, variables, procedures, and functions that are *public;* that is, available to the host (the pro- gram or unit using the unit). The host can access these entities as

|if they|were declared|that encloses|the|host.|
|---|---|---|---|---|
|interface procedure heading part|part and function|constant type declaration procedure heading|declaration and function part|part part|
|function|heading|inline directive inline,|||

##### in a block

Unless a procedure or function is the interface part only lists the procedure or function heading. The block of the procedure or function follows in the implementation part.

**implementation** The implementation part defines the block of all public proce- dures and functions. In addition, it declares constants, types, vari- **part** ables, procedures, and functions that are *private;* that is, they aren't available to the host.

implementation part **Implementation** )-,;:::======:::::;-r-1declaration part

The procedure and function declarations in the interface part are similar to forward declarations, although the **forward** directive isn't specified. Therefore, these procedures and functions can be defined and referenced in any sequence in the implementation part.

Procedure and function headings can be duplicated from the interface part. You don't have to specify the formal parameter list.

*Chapter 10, Programs and units*

If you do, the compiler will issue a compile-time error if the interface and implementation declarations don't match.

##### The initialization

**part** The initialization part is the last part of a unit. It consists either of the reserved word **end** (in which case, the unit has no initializa- tion code) or of a statement part to be executed to initialize the unit.

initialization part .~ I

#### Y statement part ~

The initialization parts of units used by a program are executed in the same order that the units appear in the **uses** clause.

##### Indirect unit

**references** The **uses** clause in a module (program or unit) need only name the units used directly by that module. Consider the following:

program Prog; uses Unit2; const a = b; begin end.

unit Unit2; interface uses Unit1; const b = c; implementation end.

unit Unit1; interface const c = 1; implementation const d = 2; end.

*Unit2* is directly dependent on *Unitl* and *Prog* is directly dependent on *Unit2.* Also, *Prog* is indirectly dependent on *Unitl* (through *Unit2),* even though none of the identifiers declared in *Unitl* are available to *Prog.*

To compile a module, the compiler must be able to locate all units the module depends upon, either directly or indirectly. So, to

*Language Guide*

compile *Prog,* the compiler must be able to locate both *Unitl* and *Unit2,* or an error occurs.

When changes are made in the interface part of a unit, other units using the unit must be recompiled. If you use Make or Build, the *"make"*compiler does this for you automatically. If changes are made *logic information traditionally* only to the implementation or the initialization part, other units *found in make or project files*that use the unit *need not* be recompiled. In the previous example, *of other languages. With the* if the interface part of *Unitl* is changed (for example, C = 2) *Unit2* *uses clause, Turbo Pascal* *can build all the depen-*must be recompiled, but changing the implementation part (for *dency information into the* example, *d* = 1) doesn't require recompiling *Unit2.* *module itself and reduce the* *chance for error.*Turbo Pascal can tell when the interface part of a unit has changed by computing a *unit version number* when the unit is compiled. In the preceding example, when *Unit2* is compiled, the current version number of *Unitl* is saved in the compiled version of *Unit2.* When *Prog* is compiled, the version number of *Unitl* is checked against the version number stored in *Unit2.* If the version numbers don't match (indicating that a change was made in the interface part of *Unitl* because *Unit2* was compiled), the compiler reports an error or recompiles *Unit2,* depending on the mode of com pila tion.

##### Circular unit

references If you place a **uses** clause in the implementation section of a unit, you hide the inner details of the unit referenced in the **uses** clause; the referenced unit is private and not available to the program or unit using the unit it's referenced in. You can use this technique to construct mutually-dependent units.

The following program demonstrates how two units can "use" each other:

|program|Circular;|||||
|---|---|---|---|---|---|
|{Display uses Crt, Display; begin ClrScr;|text using|WriteXY}||||
|WriteXY{l,|1, 'Upper|corner|of|||
|WriteXY{1000,|1000,|'Way off|the|||
|WriteXY{81 end.|-Length{'Back|to||15, 'Back|to|

left screen'); screen'); reality'), reality');

*Chapter* 70, *Programs and units*

String)

implementation

uses Display;

*Language Guide*

' + ErrMsg); end;

end.

The *Error* unit is somewhat unusual: its one declared procedure, *ShowError,* uses the *WriteXY* procedure declared in the *Display* unit, the unit that calls the *ShowError* procedure. The **uses** clause in the implementation sections of both the *Display* and *Error* units refer to each other. This is possible because Turbo Pascal can compile complete interface sections for both. The compiler accepts a reference to a partially-compiled unit in the implementation section of another unit, as long as neither unit's interface section depends upon the other. Therefore, the units follow Pascal's strict rules for declaration order.

If the interface sections are interdependent, you get a circular unit-reference error.

If you want to modify the *WriteXY* and *ShowError* procedures to take an additional parameter that specifies a rectangular window onscreen, you might write this:

procedure writeXY(SorneWindow: WindRec; X, Y: Integer; Message: String);

procedure ShowError(SomeWindow: WindRec; ErrMsg: String);

These procedures are declared in the interface sections of different units. Because both need to use the *WindRec* type, *WindRec* can't be declared in either of the interface sections-that would make them depend on each other. The solution is to create a third unit that contains only the definition of the window record:

unit WindData; interface type

|type|||
|---|---|---|
|WindRec|record||
|Xl,|Yl, X2, Y2:|Integer;|
|ForeColor,|BackColor:|Byte;|
|Active:|Boolean;||
|end;|||
|implementation|||
|end.|||

=

You can now add *WindData* to the **uses** clause in interface sections of both the *Display* and *Error* units. Both of these units

*Chapter* 70, *Programs and units*

. they can make your program harder to maintain and more susceptible to errors.

*Language Guide*

Turbo Pascal's run-time library is made up of all the standard units found in the TURBO.TPL file: *System, Dos, Overlay, Printer,* and *Crt.* This chapter briefly describes each of these units. They are loaded into memory with Turbo Pascal and are readily available to your programs.

Five other units that aren't in TURBO.TPL but that come with Turbo Pascal are *Strings, WinDos, Graph, Turb03,* and *Graph3.* They are described briefly here also.

##### System unit

The *System* unit implements low-level, run-time support routines for all built-in features, such as file I/O, string handling, floating point, and dynamic memory allocation. The *System* unit is used automatically by any unit or program and doesn't need to be referred to in a **uses** clause.

##### Dos and WinDos units

The *Dos* and *WinDos* units implement a number of very useful *WinOos*

|units, see|Chapter|75,|
|---|---|---|
|"Interfacing|with ~OS.|"|

operating system and file-handling routines. None of the routines in these units are defined by Standard Pascal, so they have been placed in their own modules. For a complete description of DOS operations, refer to a DOS programmer's reference.

*Chapter* 7, *OveNiew* of *the run-time library*

##### Crt unit

The *Crt* unit permits you to write programs that send their screen output directly to the BIOS or to video memory. The result is *"Input and* *output. "*increased speed and flexibility.

##### Printer unit

|For more about|the Printer||
|---|---|---|
|unit,|page|747 in|
|Chapter|73, "Input output."|and|
|To read about|the Overlay||
|unit, see Chapter|78, "Using overlays.|"|

The *Printer* unit lets you send standard Pascal output to your *see* printer using *Write* and *Writeln.*

##### Overlay unit

The *Overlay* unit enables you to reduce your program's total run- time memory requirements. In fact, you can write programs that are larger than the total available memory because only parts of your program will reside in memory at any given time.

##### Strings unit

|See page|767 in Chapter|76,|
|---|---|---|
|"Using|nUl/-terminated||
|for information||about|
|using|the Strings|unit.|

With Turbo Pascal's extended syntax and the *Strings* unit, your programs can use null-terminated strings, so that they are more *strings,"* compatible with any Windows programs you write.

**Graph unit**

|Read about|the Graph|unit|
|---|---|---|
|in Chapter|77, "Using|the|
|Borland Graphics|Interface.|"|

The *Graph* unit supplies a set of fast, powerful graphics routines. It implements the device-independent Borland graphics handler that supports CGA, EGA, VGA, Hercules, AT&T 400, MCGA, 3270 PC, and 8514 graphics. The *Graph* unit isn't built into TURBO.TPL, but is on the same disk with the .BGI (Borland Graphic Interface) and .CHR files.

##### Turbo3 and Graph3 units

|You'll find|information|on the|
|---|---|---|
|Turbo3 and the online|Graph3 file TURB03.INT.|units in|

These units are provided for backward compatibility only. *Turbo3* contains two variables and several procedures no longer ' supported by Turbo Pascal. *Graph3* supports the full set of graphics routines-basic, advanced, and turtlegraphics-from version 3.0.

*Language Guide*

This chapter briefly describes standard (built-in) procedures and functions in Turbo Pascal and the predeclared variables defined in the *System* unit. For in-depth information about a particular procedure, function, or predeclared variable, look it up in the alphabetical listing in Chapter I, "Library reference," in the *Programmer's Reference.*

##### This chapter covers

- Flow-control procedures
- Transfer functions
*"Input*• Arithmetic functions *and output. "* • Ordinal procedures and functions

- String procedures and functions
- Dynamic-allocation procedures and functions
- Pointer and address functions
- Miscellaneous procedures and functions,
- Predeclared variables in the *System* unit Standard procedures and functions are predeclared. Because all predeclared entities act as if they were declared in a block sur- rounding the program, you can redefine the same identifier within the program.
*Chapter* 72, *Standard procedures and functions*

These are the procedures that change the flow of logic in your procedures program:

Table 12.1

**Procedure Description** Flow-control procedures *Break* Terminates a **for, while, or repeat** statement. *Continue* Continues with the next iteration of a **for, while,** or **repeat** statement. *Exit* Exits immediately from the current block. *Halt* Stops program execution and returns to the operating system. *RunError* Stops program execution and generates a run-time error.

##### The Transfer here:

|Transfer||functions|functions|are listed||||
|---|---|---|---|---|---|---|---|
||Transfer|Table functions 12.2|Description|||||
|The transfer|procedures|Pack|Returns|a character|of a specified|ordinal|number.|
|and Standard Unpack,|Pascal,|defined are not in|Returns|the ordinal|of|ordinal-type|value.|
|implemented||by Turbo Pascal.|Rounds Truncates|a real-type a real-type|value to a value to|type a|value. value.|

**Function**

*Chr* as *Ord* number an *Round Longint* *Trunc* type *Longint*

Arithmetic functions These functions are useful in performing arithmetic operations. When you're compiling in numeric processing mode, **{$N+},** the return values of the floating-point routines in the *System* unit *(Sqrt, Pi, Sin,* and so on) are of type *Extended* instead of *Real.*

Table 12.3

**Function Description** Arithmetic functions *Abs* Returns the absolute value of the argument. *ArcTan* Returns the arctangent of the argument. *Cos* Returns the cosine of the argument.

*Exp* Returns the exponential part of the argument. *Frac* Returns the fractional part of the argument. *Int* Returns the integer part of the argument. *Ln* Returns the natural logarithm of the argument. *Pi* Returns the value of *Pi (3.1415926535897932385).*

*Language Guide*

|12.3: Arithmetic|functions|(continued)|||
|---|---|---|---|---|
||Returns Returns Returns|the sine of the square the square|the argument. of the argument. root of|the argument.|

*Sin* *Sqr* *Sqrt*

Ordinal procedures The ordinal routines operate on the ordinality of a variable. and functions

Table 12.4

Ordinal procedures and **Procedure** functions **or function Description** *Dee* Decrements a variable. *Ine* Increments a variable.

*High* Returns the highest value in the range of the argument. *Low* Returns the lowest value in the range of the argument. *Odd* Tests if the argument is an odd number. *Pred* Returns the predecessor of the argument. *Suee* Returns the successor of the argument.

String procedures and These procedures and functions are used on the traditional functions Pascal-style strings:

Table 12.5

String procedures and **Procedure** functions **or function Description**

|Coneat|Concatenates|a sequence|of strings.||
|---|---|---|---|---|
|Copy|Returns|a substring|of a string.||
|Delete|Deletes|a substring|from a string.||
|Insert|Inserts|a substring|into a string.||
|Length|Returns|the dynamic|length|of a string.|
|Pas|Searches|for a substring|in a|string.|
|Str|Converts representation.|a numeric|value to|its string|
|Val|Converts|the string|value to|its numeric|

representation.

*Chapter* 72, *Standard procedures and functions*

Dynamic-allocation The dynamic-allocation procedures and functions are used to procedures and manage the *heap-a* memory area that occupies all or some of the functions free memory left when a program is executed. Heap-management techniques are discussed in the section "The heap manager" in Chapter 19.

||Table|12.6||
|---|---|---|---|
|Dynamic-allocation|||Procedure|
|procedures|and functions||or function|

**Description**

*Dispose* Disposes of a dynamic variable. *FreeMem* Disposes of a dynamic variable of a given size. *GetMem* Creates a new dynamic variable of a given size and sets a pointer variable to point to it. *MaxAvail* Returns the size of the largest contiguous free block in the heap, indicating the size of the largest dynam- ic variable that can be allocated at the time of the call to *MaxAvail.* *MemAvail* Returns the number of free bytes of heap storage available. *New* Creates a new dynamic variable and sets a pointer variable to point to it.

Pointer and address The pointer and address functions are listed in this table: functions

|and Table address|12.7|Description|
|---|---|---|
|functions|||
|||nil.|

Pointer **Function**

|Addr|Returns|the address|of a specified|object.||
|---|---|---|---|---|---|
|Assigned|Tests|to determine|a pointer|or procedural|variable is|
|CSeg|Returns|the current|value of the|C5 register.||
|DSeg|Returns|the current|value of the|D5 register.||
|Ofs|Returns|the offset|of a specified|object.||
|Ptr|Converts pointer-type|a segment value.|base and|an offset address|to a|
|Seg|Returns|the segment|of a specified|object.||
|SPtr|Returns|the current|value of the|5P register.||
|SSeg|Returns|the current|value of the|55 register.||

if

*Language Guide*

routines Listed below are the procedures and functions that don't fit in any other category:

Table 12.8

Miscellaneous procedures **Procedure** and functions **or function Description**

|Exclude|Excludes|an element|from a set.||||
|---|---|---|---|---|---|---|
|FmChar|Fills a specified|specified number value.|of contiguous|bytes|with|a|
|Hi|Returns|the high-order|byte of|the argument.|||
|Include|Includes|an element|in a set.||||
|La|Returns|the.1ow-order|byte of|the argument.|||
|Move|Copies a source|a specified range to|number of a destination|contiguous range.|bytes|from|
|ParamCount|Returns program|the number on the command|of parameters line.|passed|to the||
|ParamStr|Returns|a specified|command-line|parameter.|||
|Random|Returns|a random|number.||||
|Randomize|Initializes value.|built-in|random generator|with|a random||
|SizeO!|Returns|number of|bytes occupied|by the|argument.||
|Swap|Swaps argument.|the high-and|low-order|bytes of|the||
|TypeO!|Points|to an object|type's virtual|method|table.||
|UpCase|Converts|a character|to uppercase.||||
|The System|also supplies|several|predeclared|variables:|||
|ErrorAddr|Pointer|Run-time|error address||||
|ExitCode|Integer|Exit code|||||
|ExitProc|Pointer|Exit procedure|||||
|FileMode|Byte|File open|mode||||
|FreeList|Pointer|Free heap-block|list||||
|FreeZero|Pointer|Free zero|||||
|HeapEnd|Pointer|Heap end|||||
|HeapError|Pointer|Heap-error|function||||
|HeapOrg|Pointer|Heap origin|||||
|HeapPtr|Pointer|Heap pointer|||||
|Input|Text|Input standard|file||||
|InOutRes|Integer|IIO result|buffer||||
|Output|Text|Output|standard file||||

##### Predeclared variables unit

Table 12.9

Predeclared variables in the **Variable Type Description** System unit

*Chapter* 12, *Standard procedures and functions*

Predeclared variables

|in the|System|unit (continued)||
|---|---|---|---|
|Overlay|code-segment||list|
|Overlay-debugger||||
|Overlay|DOS|||
|Overlay|EMS|||
|Overlay-buffer||||
|Overlay-buffer||origin||
|Overlay-buffer||||
|Initial|overlay-buffer||size|
|Loaded-overlays||list||
||Segment|Prefix||
||seed|||
|Saved||$00||
|Saved||$02||
|Saved||$1B||
|Saved||$21||
|Saved||$23||
|Saved||$24||
|Saved||$34||
|Saved||$35||
|Saved||$36||
|Saved||$37||
|Saved||$38||
|Saved||$39||
|Saved||$3A||
|Saved||$3B||
|Saved||$3C||
|Saved||$3D||
|Saved||$3E||
|Saved||$3F||
|Saved||$75||
|Selector|for segment||$0040|
|Selector|for segment||$AOOO|
|Selector|for segment||$BOOO|
|Selector Selector|for segment increment||$B800|
||stack|||
|80x87|test result|||

|OvrCodeList||Word||||
|---|---|---|---|---|---|
|OvrDebugPtr||Pointer||hook||
|OvrDosHandle||Word||handle||
|OvrEmsHandle||Word||handle||
|OvrHeapEnd||Word||end||
|OvrHeapOrg||Word||||
|OvrHeapPtr||Word||pointer||
|OvrHeapsize||Word||||
|OvrLoadList||Word||||
|Prefixseg||Word|Program|||
|Randseed||Longint|Random|||
|Sa veIn|tOO|Pointer|interrupt|||
|saveInt02||Pointer|interrupt|||
|saveIntlB||Pointer|interrupt|||
|saveInt21||Pointer|interrupt|||
|saveInt23||Pointer|interrupt|||
|saveInt24||Pointer|interrupt|||
|saveInt34||Pointer|interrupt|||
|saveInt35||Pointer|interrupt|||
|saveInt36||Pointer|interrupt|||
|saveInt37||Pointer|interrupt|||
|saveInt38||Pointer|interrupt|||
|saveInt39||Pointer|interrupt|||
|saveInt3A||Pointer|interrupt|||
|saveInt3B||Pointer|interrupt|||
|saveInt3C||Pointer|interrupt|||
|saveInt3D||Pointer|interrupt|||
|saveInt3E||Pointer|interrupt|||
|saveInt3F||Pointer|interrupt|||
|saveInt75||Pointer|interrupt|||
|seg0040||Word||||
|segAOOO||Word||||
|segBOOO||Word||||
|segB800||Word||||
|selectorInc||Word||||
|5 tackLim|it|Word|Minimum|pointer||
|Test8087||Byte||||
|For more|information|about|these variables,look||them in|
|alphabetical|listing|in Chapter|I, "Library|reference,"|of the|
|Programmer's|Reference.|||||

up the

*Language Guide*

##### A p T E R

**13**

#### Input and output

|This chapter|describes|the standard|(or built-in)|input|and output|
|---|---|---|---|---|---|
|(I/O) procedures|and|functions|of Turbo Pascal;|you'll|find them|
|in the System|unit.|also discusses|input and|output issues|such|
|as file input text-file device|and output, drivers.|devices,|using the|Crt unit, printing,|and|

It

Table 13.1

**Procedure** Input and output procedures and functions **or function Description**

|Append|Opens|an existing|text file for|appending.||
|---|---|---|---|---|---|
|Assign|Assigns|the name|of an external|file to|a file variable.|
|BlockRead|Reads|one or more|records from|an untyped|file.|
|BlockWrite|Writes|one or more|records|into an untyped|file.|
|ChDir|Changes|the current|directory.|||
|Close|Closes|an open file.||||
|Eo!|Returns|the end-of-file|status|of a file.||
|Eoln|Returns|the end-of-line|status|of a text|file.|
|Erase|Erases|an external|file.|||
|FilePos|Returns untyped|the current file.|file position|of a typed|or|
|FileSize|Returns files.|the current|size of a|file; not used|for text|
|Flush|Flushes|the buffer|of an output|text file.||
|GetDir|Returns|the current|directory|of a specified|drive.|

*Chapter* 13, *Input and output*

|110 function|performed.||||
|---|---|---|---|---|
|Creates|a subdirectory.||||
|Reads one more variables.|more values|from a|file into one||
|Does|a does|skips|to||
|beginning|of the next|line text|file.||
|Renames|external existing file.||||
|Creates|opens a|file.|||
|Removes|subdirectory.||||
|Moves|position|of a|||
|file to a files.|specified component.|||text|
|Returns|the end-of-file|status a|text file.||
|Returns|the end-of-line|status of a|text file.||
|Assigns|0 buffer|to a text file.|||
|Truncates position.|a|file||file|
|Writes one|values|to a file.|||
|Does the|as a||writes|end-|
|of-line|to|file.|||

or or

what *Read* and then the in the an file. Opens an and new an empty the current typed or untyped Not used with I

of

an 1/ typed or untyped at the current

or more same *Write,* and then an marker the text

#### File input and output

|The syntax|for writing|file|
|---|---|---|
|types is given|in the section||
|"File types"|on page|42.|

|A Pascal|file variable|is any variable|whose|type is a file|type.|
|---|---|---|---|---|---|
|There are|three classes|of Pascal|files: typed,|text, and untyped.||
|Before a|file variable|can be used,|it must be|associated|with an|
|external|file through|a call to the|Assign procedure.|An|external|
|file is typically|a named|disk file,|it can|also be a device,|such|
|as the keyboard|or|the display.|The external|file stores|the infor-|
|mation written the file.|to the|file or supplies|the information||read from|
|Once the|association|with an external|file is|established,|the file|
|variable|must be "opened"|to prepare|for|input or output.|An|
|existing|file can be|via|Reset procedure,|and|a new file|
|can be created|and|opened via|the Rewrite||Text files|

but

it opened the procedure.

*Language Guide*

opened with *Reset* are read-only, and text files opened with *Rewrite* and *Append* are write-only. Nontext files always allow both reading and writing whether or not they were opened with *Reset* or *Rewrite.*

Every file is a linear sequence of components, each of which has the component type (or record type) of the file. Each component has a component number. The first component of a file is con- sidered to be component zero.

Files are normally accessed *sequentially;* that is, when a component is read using the standard procedure *Read* or written using the standard procedure *Write,* the current file position moves to the next numerically ordered file component. Typed files and untyped files can also be accessed randomly via the standarq procedure *Seek,* which moves the current file position to a speci- fied component. The standard functions *FilePos* and *FileSize* can be used to determine the current file position and the current file size.

When a program completes processing a file, the file must be closed using the standard procedure *Close.* After a file is closed, its associated external file is updated. The file variable can then be associated with another external file.

By default, all calls to standard I/O procedures and functions are automatically checked for errors: If an error occurs, the program terminates, displaying a run-time error message. This automatic checking can be turned on and off using the **{$I+}** and **{$I-}** com- piler directives. When I/O checking is off-that is, when a proce- dure or function call is compiled in the **{$I-}** state-an I/O error doesn't cause the program to halt. To check the result of an I/O operation, you must call the standard function *IOResult* instead.

):' ou must call the *IOResult* function to clear whatever error might have occurred, even if you aren't interested in the error. If you don't and **{$I+}** is the current state, the next I/O function call fails with the lingering *IOResult* error.

**files** *In Turbo Pascal, the type*This section summarizes 1/ a using file variables of the standard *Text is distinct from the type* type *Text.* *file of Char.* When a text file is opened, the external file is interpreted in a special way: It's considered to represent a sequence of characters formatted into lines, where each line is terminated by an end-of-

*Chapter* 13, *Input and output*

"); Reset (Input); Assign (Output, "); Rewrite (Output);

*Input* and *Output* are automatically closed after a program finishes executing.

If a program uses the *Crt* standard unit, *Input* and *Output* no longer refer to the standard input and output files.

Some of the standard I/O routines that work on text files don't need to have a file variable explicitly given as a parameter. If the file parameter is omitted, *Input* or *Output* is assumed by default, depending on whether the procedure or function is input-or output-oriented. For example, *Read(X)* corresponds to *Read(Input,*

X) and *Write(X)* corresponds to *Write(Output,* X). If you do specify a file when calling one of the input or output routines that work on text files, the file must be associated with an external file using *Assign,* and opened using *Reset, Rewrite,* or *Append.* A run-time error occurs if you pass a file that was opened with *Reset* to an output-oriented procedure or function. Likewise, it's an error to pass a file that was opened with *Rewrite* or *Append* to an input-oriented procedure or function.
*Language Guide*

**files**

Untyped files are low-level I/O channels primarily used for direct access to any disk file regardless of type and structuring. An un- typed file is declared with the word **file** and nothing more. For example,

var DataFile: file;

For untyped files, the *Reset* and *Rewrite* procedures allow an extra parameter to specify the record size used in data transfers. For historical reasons, the default record size is 128 bytes. A record size of 1 is the only value that correctly reflects the exact size of any file, because no partial records are possible when the record size is 1.

Except for *Read* and *Write,* all typed-file standard procedures and functions are also allowed on untyped files. Instead of *Read* and *Write,* two procedures called *BlockRead* and *BlockWrite* are used for high-speed data transfers.

##### The FileMode

**variable** The *FileMode* variable defined by the *System* unit determines the access code to pass to DOS when typed and untyped files (not text files) are opened using the *Reset* procedure.

*New files created using*The default *FileMode* is 2, which allows both reading and writing. *Rewrite are always opened* Assigning another value to *FileMode* causes all subsequent *Resets* *in read/write mode,* *corresponding to*to use that mode. *FileMode=2.* The range of valid *FileMode* values depends on the version of DOS in use. For all versions, however, the following modes are defined:

##### o Read only

##### 1 Write only

##### 2 Read/Write

DOS version 3.x and higher defines additional modes, which are primarily concerned with file-sharing on networks. (For more details, see your DOS programmer's reference manual.)

*Chapter* 73, *Input and output*

##### Pascal

Turbo Pascal and the DOS operating system regard external hardware, such as the keyboard, the display, and the printer, as *devices.* From the programmer's point of view, a device is treated as a file and is operated on through the same standard procedures and functions as files.

Turbo Pascal supports two kinds of devices: DOS devices and text-file devices.

##### DOS devices

DOS devices are implemented through reserved file names that have a special meaning attached to them. DOS devices are com- pletely transparent-in fact, Turbo Pascal isn't even aware when a file variable refers to a device instead of a disk file. For example, the program

var Lst: Text; begin

|begin|||
|---|---|---|
|Assign(Lst,|'LPT1');||
|Rewrite(Lst);|||
|Writeln(Lst,|'Hello|World|
|Close(Lst)|;||
|end.|||
||"Hello|World|

##### ... ');

writes the string ... " on the printer, even though the syntax for doing so· is exactly the same as for a disk file.

The devices implemented by DOS are used for obtaining or presenting legible input or output. Therefore, DOS devices are normally used only in connection with text files. On rare occa- sions, untyped files can also be useful for interfacing with DOS devices.

The CON device CON refers to the CONsole device, in which output is sent to the display, and input is obtained from the keyboard. The *Input* and *Output* standard files and all files assigned an empty name refer to the CON device when input or output isn't redirected.

Input from the CON device is line-oriented and uses the line- editing facilities described in your DOS manual. Characters are read from a line buffer, and when the buffer becomes empty, a new line is input.

*Language Guide*

An end-of-file character is generated by pressing *Ctrl+Z,* after which the *Eo!* function will return *True.*

The line-printer devices are the three possible printers you can use. If only one printer is connected, it's usually referred to as LPTl, for which the synonym can also be used.

The line-printer devices are output-only devices-an attempt to *Reset* a file assigned to one of these generates an immediate end- of-file.

The standard unit *Printer* declares a text-file variable called *Lst,* and makes it refer to the LPTI device. To easily write something on the printer from one of your programs, include *Printer* in the program's **uses** clause, and use *Write(Lst, ... )* and *Writeln(Lst, .. .)* to produce your output.

COM 1 and COM2 The communication-port devices are the two serial communi- devices cation ports. The synonym AUX can be used instead of COMl.

The NUL device The NUL device ignores anything written to it, and generates an immediate end-of-file when read from. You should use this when you don't want to create a particular file, but the program requires an input or output file name.

##### Text-file devices

by

|Text-file|devices|are used to|implement|devices unsupported|||
|---|---|---|---|---|---|---|
|DOS or|to provide|another set|of features|similar|to those||
|supplied|by another|DOS device.|A good|example|of a text-file||
|device|is the CRT|device implemented||by the Crt|standard|unit.|
|provides|an interface|to the|display and|the keyboard,|like|the|
|CON device|in DOS,|but the|CRT device|is much|faster and||
|supports|such invaluable|features|as color|and windows.|||
|Unlike|DOS devices,|text-file|devices have|no reserved|file|names;|
|in fact,|they have|no file names|at all. Instead,|a file|is associated||
|with a|text-file device|through|a customized|Assign|procedure.||
|For example,|the|Crt standard|unit implements|an|AssignCrt||
|procedure|that associates|text|files with|the CRT window.|||

It

*Chapter* 13, *Input and output*

#### and output with the Crt unit

The *Crt* unit implements a range of powerful routines that give you full control of your PC's features, such as screen mode control, extended keyboard codes, colors, windows, and sound. *Crt* can only be used in programs that run on IBM PCs, A Ts, PS/2s, and true compatibles.

One of the major advantages to using *Crt* is the added speed and flexibility of screen output operations. Programs that don't use the *Crt* unit send their screen output through DOS, which adds a lot of overhead. With the *Crt* unit, output is sent directly to the BIOS or, for even faster operation, directly to video memory.

##### Using the Crt unit

To use the *Crt* unit, include it in your program's uses clause as you would any other unit:

uses Crt;

The initialization code of the *Crt* unit assigns the *Input* and *Output* standard text files to refer to the CRT instead of to DOS's standard input and output files. These statements execute at the beginning of a program:

|AssignCrt(Input);|Reset (Input)|;|
|---|---|---|
|AssignCrt(Output);|Rewrite|(Output);|

This means that I/O redirection of the *Input* and *Output* files is no longer possible unless these files are explicitly assigned back to input and this:

|standard|output|by executing|
|---|---|---|
|Assign(Input,|Reset (Input)|;|
|Assign|Rewrite|(Output);|

"); (Output, ");

Windows

*Crt* supports a simple yet powerful form of windows. The *Window* procedure lets you define a window anywhere on the screen. When you write in such a window, the window behaves exactly as if you were using the entire screen, leaving the rest of the screen untouched. In other words, the screen outside the window isn't accessible. Inside the window, lines can be inserted and deleted, the cursor wraps around at the right edge, and the text scrolls when the cursor reaches the bottom line.

*Language Guide*

Special charactArs When writing to *Output* or a file that has been assigned to the CRT, the following control characters have special meanings:

Table 13.2

**Char Name Description** Control characters #7 BELL Emits a beep from the internal speaker. #8 BS Moves the cursor left one column. If the cursor is already at the left edge of the current window, nothing happens. #10 LF Moves the cursor down one line. If the cursor is already at the bottom of the current window, the window is scrolled up one line. #13 CR Returns the cursor to the left edge of the current window.

Line input When reading from *Input* or from a text file that has been assigned to *Crt,* text is input one line at a time. The line is stored in the text file's internal buffer, and when variables are read, this buffer is used as the input source. Whenever the buffer has been emptied, a new line is input.

When entering lines, the following editing keys are available:

Table 13.3

**Editing key Description** Line input editing keys *Backspace* Deletes the last character entered. *Esc* Deletes the entire input line. *Enter* Terminates the input line and stores the end-of-line marker (carriage return/line feed) in the buffer. *Ctrl+S* Same as *Backspace.* *Ctrl+D* Recalls one character from the last input line. *Ctrl+A* Same as *Esc.* *Ctrl+F* Recalls the last input line. *Ctrl+Z* Terminates the input line and generates an end-of-file marker.

*Chapter* 73, *Input and output*

an if

|Ctrl+Zwill|only generate||end-of-file|marker|the CheckEOF|
|---|---|---|---|---|---|
|variable|has been|set to True;|it's False|default.||
|To test|keyboard|status and|input single|characters|under|
|program|control,|use the KeyPressed||and ReadKey|functions.|

by

|The|following|table|lists|the|procedures|and|functions|defined|in|
|---|---|---|---|---|---|---|---|---|---|
|the|Crt unit. Procedure or function||Description|||||||

Table 13.4

Crt unit procedures and functions

|AssignCrt|Associates|a text file with|the CRT|window.||
|---|---|---|---|---|---|
|ClrEol|Clears all the the end of|characters the line.|from the|cursor position|to|
|ClrScr|Clears the left-hand corner.|screen and|returns cursor|to the upper||
|Delay|Delays a specified|number|of milliseconds.|||
|DelLine|Deletes the lines below cleared.|line containing that line one|the cursor line up.|and moves The bottom|all line is|
|GotoXY|Positions the the vertical|cursor. X position.|is the horizontal|position.|Y is|
|High Video|Selects high-intensity||characters.|||
|InsLine|Inserts an empty|line at|the cursor|position.||
|KeyPressed|Returns True keyboard.|a key has|been pressed|on the||
|Low Video|Selects low-intensity|characters.||||
|Norm Video|Selects normal|characters.||||
|NoSound|Turns off the|internal|speaker.|||
|Sound|Starts the internal|speaker.||||
|TextBackground|Selects the|background|color.|||
|TextColor|Selects the|foreground|character|color.||
|TextMode|Selects a specific text|mode.||||
|Window|Defines a text|window|onscreen.|||
|ReadKey|Reads a character|from|the keyboard.|||

See *the Programmer's* *Reference for more details* *about using the Crt* *procedures and functions.*

if

*Language Guide*

|Table 13.4:|Crt unit|procedures|and functions|(continued)|||
|---|---|---|---|---|---|---|
|||Returns location, Returns location,|the x-coordinate relative the y-coordinate relative|of to current of to the current|the current window. the current window.|cursor cursor|

*WhereX* the *WhereY*

**and variables** The *Crt* unit has several constants that your programs can use. To learn more about using them, look them up in Chapter 1 of the

|||Programmer's|Reference.|You'll find|them grouped|like|this:|
|---|---|---|---|---|---|---|---|
|Crt unit Table constants|13.5|Constant Text color|group constants constants|Description Graphics-mode for Constants|constants procedure. to set|the colors|as of the CRT|
||||||the procedures.|||

Crt mode used parameters the *TextMode* used window using *TextColor* and *TextBackground*

For example, to find the value of a constant that will color the text in your program red, look up Text Color constants, and you'll discover that the constant *Red* has a value of 4. These are the variables in the *Crt* unit and the functions they perform:

Table 13.6

**Variable Description** crt unit variables *CheckBreak* Enables and disables checks for *Ctrl+Break.* *CheckEOF* Enables and disables the end-of-file character. *CheckSnow* Enables and disables "snow checking". *Direct Video* Enables and disables direct memory access for *Write* and *Writeln* statements that output to the screen. *LastMode* Stores the current video mode when each time *TextMode* is called. *TextAttr* Stores the currently-selected text attributes. *WindMin* Stores the screen coordinates of the upper-left comer of the current window. *WindMax* Stores the screen coordinates of the lower-right corner of the current window.

*Chapter* 73, *Input and output*

Pascal lets you define your own text-file device drivers. A text-file device driver is a set of four functions that completely implement an interface between Turbo Pascal's file system and some device.

The four functions that define each device driver are *Open, InOut,* *Flush,* and *Close.* The function header of each function is

function DeviceFunc(var F: TTextRec): Integer;

where *TTextRec* is the text file record type defined in the "Internal data formats," section in Chapter 19. Each function must be compiled in the **{$F+}** state to force it to use the far call model. The return value of a device-interface function becomes the value returned by *IOResult.* If the return value is zero, the operation was successful.

To associate the device-interface functions with a specific file, you must write a customized *Assign* procedure (like the *AssignCrt* procedure in the *Crt* unit). The *Assign* procedure must assign the addresses of the four device-interface functions to the four func- tion pointers in the text file variable. **In** addition, it should store the *fmClosed* "magic" constant in the *Mode* field, store the size of the text file buffer in *BufSize,* store a pointer to the text file buffer in *BufPtr,* and clear the *Name* string.

For example, assuming that the four device-interface functions are called *DevOpen, DevlnOut, DevFlush,* and *DevClose,* the *Assign*

|procedure|might look|like this:|
|---|---|---|
|procedure begin|AssignDev(var|F: Text);|
|with TextRec(F) begin|do||
|Mode|:= fmClosed;||
|BufSize|:= SizeOf(Buffer);||
|BufPtr|:= @Buffer;||
|OpenFunc|:= @DevOpen;||
|InOutFunc|:= @DevInOut;||
|FlushFunc|:= @DevFlush;||
|CloseFunc|:= @DevClose;||
|Name[O] end; end;|:= #0;||

*Language Guide*

The device-interface functions can use the *UserData* field in the file record to store private information. This field isn't modified by the Turbo Pascal file system at any time.

##### Open function

|The|Open|function|is|called|by|the|Reset,|Rewrite,|and|Append|
|---|---|---|---|---|---|---|---|---|---|---|
|standard||procedures||to open||a text|file|associated|with|a device.|
|On|entry,|the Mode|field||contains||fmlnput,|fmOutput,||or fmlnOut to|
|indicate or|Append.|whether|the|Open|function||was|called|from|Reset, Rewrite,|
|The|Open|function|prepares||the|file|for|input|or output,|according|
|to|the Mode|value.|If|Mode|specifiedfmlnOut||||(indicating|that Open|
|was Open|called returns.|from|Append),||it must||be changed||to fmOutput|before|
|Open|is|always|called|before|any||of the|other|device-interface||
|functions.||For that|reason,||AssignDev||only|initializes||the OpenFunc|
|field,leaving||initialization|||of|the|remaining|vectors||up to Open.|
|Based|on|Mode,|Open|can|then|install|pointers||to either|input- or|
|output-oriented|||functions.||This|saves||the InOut,|Flush|functions|
|and|the|Close procedure|||from|determining||the|current|mode.|
|The|InOut|function|is|called|by|the|Read,|Readln,|Write,|Writeln,|
|Eof,|Eoln,|SeekEof,|SeekEoln,||and|Close|standard||procedures|and|
|functions||whenever||input|or output||from|the|device|is required.|
|When|Mode|is fmlnput,||the|InOut||function|reads|up|to BufSize|
|||||A|||||||
|characters||into|BufPtr|, and|returns||the|number|of|characters read|
|in|BufEnd.|In addition,||it|stores|zero|in|BufPos.|If the|InOut|
|function becomes||returns True for|zero the|in BufEnd file.||as|a result|of|an input|request, Eof|
|When|Mode|is fmOutput,|||the InOut||function|writes|BufPos||
|||||A|||||||
|characters||from|BufPtr|,|and|returns|zero|in|BufPos.||

##### The InOut function

##### The Flush function

The *Flush* function is called at the end of each *Read, Readln, Write,* and *Writeln.* It can optionally flush the text file buffer.

*Chapter* 13, *Input and output*

If *Mode* is *jmlnput,* the *Flush* function can store zero in *BufPos* and *BufEnd* to flush the remaining (unread) characters in the buffer. This feature is seldom used.

If *Mode* is *jmOutput,* the *Flush* function can write the contents of the buffer exactly like the *InOut* function, which ensures that text written to the device appears on the device immediately. If *Flush* does nothing, the text won't appear on the device until the buffer becomes full or the file is closed.

Close function function

|The Close|is called|by the|Close standard|procedure|to|
|---|---|---|---|---|---|
|close a text|file associated|with a device.|(The|Reset, Rewrite,|and|
|Append procedures|also|call Close|the file they|are opening|is|
|already open.)|Mode|is jmOutput,|then before|calling Close,||
|Turbo Pascal's|file system|calls the|InOut function|to ensure|that|
|all characters|have been|written to|the device.|||

if If

*Language Guide*

Pascal: integers *(Shortint, Integer, Longint, Byte, Word)* and reals *(Real, Single, Double, Extended, Camp).* Reals are also known as floating-point numbers. The 80x86 family of processors is designed to handle integer values easily, but handling reals is considerably more difficult. To improve floating-point perform- ance, the 80x86 family of processors has a corresponding family of math coprocessors, the 80x87s.

The 80x87 is a special hardware numeric processor that can be installed in your PC. It executes floating-point instructions very quickly, so if you use floating point often, you'll probably want a numeric coprocessor or a 80486 processor, which has a numeric coprocessor built in.

Turbo Pascal provides optimal floating-point performance whether or not you have an 80x87:

- For programs running on any PC, with or without an 80x87, Turbo Pascal provides the *Real* type and an associated library of software routines that handle floating-point operations. The *Real* type occupies 6 bytes of memory, providing a range of 2.9 x 10- 39 to 1.7 X 10
38 with 11 to 12 significant digits. The software floating-point library is optimized for speed and size, trading in some of the fancier features provided by the 80x87 processor.

- If you need the added precision and flexibility of the 80x87, you can instruct Turbo Pascal to produce code that uses the 80x87 chip. This gives you access to four additional real types *(Single,*

##### Double, Extended, and Camp), and an Extended floating-point

range of 3.4 x 10- 4951 to 1.1 X 10 4932 with 19 to 20 significant digits.

You switch between the two different models of floating-point code generation using the **$N** compiler directive or the 80x87 Code check box in the Options I Compiler dialog box. The default state is {$N-}, and in this state, the compiler uses the 6-byte floating-point library, allowing you to operate only on variables of type *Real.* In the {$N+} state, the compiler generates code for the 80x87, giving you increased precision and access to the four additional real types.

When you're compiling in 80x87 Code mode, {$N+},the return values of the floating-point routines in the *System* unit *(Sqrt, Pi,* *Sin,* and so on) are of type *Extended* instead of *Real:*

{$N+} begin

|begin|||
|---|---|---|
|Writeln(Pi)|{3.14159265358979E+OOOO|}|
|end.|||
|{$N-}|||
|begin|||
|Writeln(Pi)|{3.1415926536E+OO|}|
|end.|||

i

|Even if|you don't have|an 80x87|in your machine,|you|can instruct|
|---|---|---|---|---|---|
|TurboPascal|to include|a run-time|library|that emulates|the|
|numeric|coprocessor.|Then, if|80x87 is|it's|used. it's|
|not present,|the run-time|library|emulates|it, although|your|
|program|runs a bit|than|if an 80x87|were present.||
|The $E|compiler directive|and|the Emulation|check box|in the|
|Options|I Compiler|box|are used to|enable and|disable|
|80x87 emulation.|The|default state|is {$E+},|and in this|state, the|
|full80x87|emulator|is automatically|included|in programs|that|
|use the|80x87. In the|{$E-} state,|a substantially|smaller|floating-|
|point library machines|is used, with an|and the final.EXE|file|can only|on|
|The $E|compiler directive|has no|effect if|used in a unit;|it only|
|applies|to the compilation|of a|program. Also,|if the|program is|
|compiled|in the {$N-}|state, and|if all the units|used by|the|
|program|were compiled|with {$N-},|then|80x87 run-time||
|library|isn't required,|and the $E|compiler|directive|is ignored.|

##### an present, If

slower

dialog

run 80x87.

an

*Language Guide*

For programs that use the 80x87, Turbo Pascal provides four floating-point types in addition to the type *Real.*

- The *Single* type is the smallest format you can use with floating-point numbers. It occupies 4 bytes of memory, providing a range of 1.5 x 10-
45 to 3.4 X 10 38 with 7 to 8 significant digits.

- The *Double* type occupies 8 bytes of memory, providing a range of 5.0 x 10-
324 to 1.7 X 10 308 with 15 to 16 significant digits.

- The *Extended* type is the largest floating-point type supported by the 80x87.1t occupies 10 bytes of memory, providing a range of 3.4 x 10-
4932 to 1.1 X 10 4932 with 19 to 20 significant digits. Any arithmetic involving real-type values is performed with the range and precision of the *Extended* type.

- The *Comp* type stores integral values in 8 bytes, providing a. range of _2
63 + 1 to 2 63 -1, which is approximately-9.2 x 10 18 to

9.2 X 10 18. *Camp* can be compared to a double-precision *Longint,* but it's considered a real type because all arithmetic done with *Comp* uses the 80x87 coprocessor. *Comp* is appropriate for representing monetary values as integral values of cents or mils (thousandths) in business applications.
Whether or not you have an 80x87 processor, the 6-byte *Real* type is always available, so you don't have to modify your source code when switching to the 80x87, and you can still read data files generated by programs that use software floating point.

Note, however, that 80x87 floating-point calculations on variables of type *Real* are slightly slower than on other types. This is because the 80x87 can't directly process the *Real* format-instead, calls must be made to library routines to convert *Real* values to *Extended* before operating on them. If you're concerned with optimum speed and always run on a system with an 80x87, you might want to use the *Single, Double, Extended,* and *Comp* types exclusively.

##### 74, Using the 80x87

||80x87.|Turbo Pascal|uses the Extended|format|to store|all|
|---|---|---|---|---|---|---|
|non-integer|numeric|constants|and evaluates|all non-integer|||
|numeric|expressions|using|precision.|The entire|right||
|side of|the following|assignment,|for example,|is computed||in|
|Extended|before|being converted|to the type|the left|side:||

extended

on

{$N+} var X *IA IB IC:* Real; begin

|begin|||
|---|---|---|
|X :=|(B + Sqrt(B|B -A|
|end;|||

* * Cll / A;
Turbo Pascal automatically performs computations using the precision and range of the *Extended* type. The added precision means smaller round-off errors, and the additional range means overflow and underflow are less common.

You can go beyond Turbo Pascal's automatic *Extended* capabilities. For example, you can declare variables used for intermediate results to be of type *Extended.* The following example computes a sum of products:

var Sum: Single; *X,* Y: array[1 .. 100] of Single; I: Integer; T: Extended; { For intermediate results } begin T := 0.0; for I := 1 to 100 do begin XlI] := I; Y[I [ := I; T := T + XlI] * Y[I]; end; Sum := T; end;

Had *T* been declared *Single,* the assignment to *T* would have caused a round-off error at the limit of single precision at each loop entry. But because *T* is *Extended,* all round-off errors are at the limit of extended precision, except for the one resulting from

*Language Guide*

##### Sum. Fewer round-off errors mean more

accurate results.

You can also declare formal value parameters and function results to be of type *Extended.* This avoids unnecessary conversions between numeric types, which can result in loss of accuracy. For example,

function Area {Radius: Extended): Extended; begin

|begin|||
|---|---|---|
|Area|:= pi Radius|Radius;|
|end;|||

* *
#### Comparing reals

|Because|real-type|values are|approximations,|the results|of||
|---|---|---|---|---|---|---|
|comparing|values|of different|real types|aren't always|as||
|expected.|For example,|if X|is a variable|of type Single|and Y|is a|
|variable|of type|Double, then|the following|statements|are False:||

##### x := 1 / 3;

Y := 1 / 3; Writeln(X = Y);

This is because X is accurate only to 7 to 8 digits, where Y is accurate to 15 to 16 digits, and when both are converted to *Extended,* they differ after 7 to 8 digits. Similarly, the statements

##### x := 1 / 3;

Writeln{X = 1 / 3);

are *False,* because the result of 1/3 in the *Writeln* statement is calculated with 20 significant digits.

#### The 80x87 evaluation stack

The 80x87 coprocessor has an internal evaluation stack that can be as deep as eight levels. Accessing a value on the 80x87 stack is much faster than accessing a variable in memory. To achieve the best possible performance, Turbo Pascal uses the 80x87's stack for storing temporary results.

##### In theory, very complicated real-type expressions can overflow

the 80x87 stack. This isn't likely to occur, however, because the

*Chapter* 74, *Using the BOxB7*

##### SOxS7 stack.

Consider the following procedure that calculates Fibonacci numbers using recursion:

function Fib(N: Integer): Extended; begin if N = a then

|N =|then||
|---|---|---|
|Fib := else|0.0||
|N|1 then||
|Fib : else|= 1.||
|Fib := Fib(N|-1) +|Fib(N-2);|

if = a

end;

A call to this version of *Fib* will cause an SOxS7 stack overflow for values of N larger than S. This is because the calculation of the last assignment requires a temporary on the SOxS7 stack to store the result of *Fib(N-1).* Each recursive invocation allocates one such temporary, causing an overflow the ninth time. The correct construct in this case is this:

function Fib(N: Integer): Extended; var F1, F2: Extended; begin if N = a then Fib := 0.0 else if N = 1 then Fib := 1.0 else begin F1 := Fib(N-1); F2 := Fib(N-2); Fib := F1 + F2; end; end;

in

|The temporary||results are|now stored|variables|allocated|on the|
|---|---|---|---|---|---|---|
|SOS6 stack.|(The|SOS6 stack|can also|overflow|this would||
|usually|require|many more|recursive|calls.)|||

*I* but

*Language Guide*

#### reals with the 80x87

In the {$N+} state, the *Write* and *Writeln* standard procedures output four digits, not two, for the exponent in a floating-point decimal string to provide for the extended numeric range. The *Str* standard procedure also returns a four-digit exponent when floating-point format is selected.

#### Units using the 80x87

|Units that|use the 80x87|can be|used only|by other|units or||
|---|---|---|---|---|---|---|
|programs|that are compiled|in|the {$N+}|state.|||
|The fact|that a unit|uses the 80x87|is determined||whether|it|
|contains|80x87||by the state|of the|$N compiler||
|directive|at the time|of its compilation.|This|makes|the compiler||
|more forgiving|in cases|where|you accidentally|compile|a|unit|
|that doesn't|use the|80x87 in the|{$N+} state.||||
|When you|compile|in numeric|processing|mode ({$N+}),|the||
|return values|of the|floating-point|routines|in the System|||
|Sqrt, Pi,|Sin, and so|of|type Extended|instead|of Real.||

by instructions-not

unit- on-are

##### Detecting the

|The Turbo|Pascal 80x87|run-time|library|built into|your program||
|---|---|---|---|---|---|---|
|(compiled|with {$N+})|includes|startup code|that|automatically||
|detects|the presence|of 80x87|chip. If|an 80x87|is available,|then|
|the program|will use|it. If one|isn't present,|the program|will|use|
|the emulation run-time||library.|If the program|was|compiled|in|
|the {$E-}|state, and|an 80x87 could|not be|detected|at startup,|the|
|program|displays|coprocessor||required,"|and ends.||
|You might|want to|override this|default|auto detection|behavior||
|occasionally.|For example,|your|own system|might|have an|80x87,|
|but you|want to verify|that your|program|will work|as intended||
|on systems|without|a coprocessor.|Or your|program|might|need|
|to run on|a PC-compatible|system,|that|particular|system||
|returns|incorrect information||to the auto|detection|logic (saying||
|that an|80x87 is present|when|it's not, or|vice versa).|||
|Turbo Pascal|provides|an option|for overriding|the|startup|code's|
|default|autodetection|logic: the|87 environment|variable.|||

80x87

an

"Numeric

but

*Chapter* 74, *Using the BOxB7*

You set the 87 environment variable at the DOS prompt with the SET command, like this:

SET 87 = y

or

SET 87 = N

Setting the 87 environment variable to N (for no) tells the startup code that you don't want to use the 80x87, even though it might be present in the system. Conversely, setting the 87 environment variable to Y (for yes) means that the coprocessor is there, and you want the program to use it..

If you set *S7* = Y when there is no 80x87 available, your program will either crash or hang!

If the *S7* environment variable has been defined (to any value) but you want to undefine it, enter this at the DOS prompt:

SET 87 =

If an 87 = Y entry is present in the DOS environment, or if the autodetection logic succeeds in detecting a coprocessor, the startup code executes additional checks to determine what kind of coprocessor it's (8087, 80287, or 80387). This is required so that Turbo Pascal can correctly handle certain incompatibilities that exist between the different coprocessors.

The result of the auto detection and the coprocessor classification is stored in the *TestSDS7* variable (which is declared by the *System* following

|||unit). The|values|are defined:|
|---|---|---|---|---|
|variable Table|values 14.1|Value 2|Definition coprocessor 8087 detected 80287 detected|detected|
|||3|80387|80486 detected|

Test8087 o No 1

or

Your program can examine the *Test8DS7* variable to determine the characteristics of the system it's running on. In particular, *TestSDS7* can be examined to determine if floating-point instructions are being emulated or truly executed.

*Language Guide*

When linking in object files using **{$L** *filename}* directives, make sure that these object files were compiled with the 80x87 emulation enabled. For example, if you're using 80x87 instructions in assembly language **external** procedures, enable emulation when you assemble the .ASM files into .OBJ files. Otherwise, the 80x87 instructions can't be emulated on machines without an 80x87. Use Turbo Assembler's ***IE*** command-line switch to enable emulation.

*Chapter* 74, *Using the 80x87 .*

##### A p T E R

**15**

#### Interfacing with DOS

The *Dos* and *WinDos* units implement a number of operating system and file-handling routines. None of the routines in the *Dos* and *WinDos* units are defined by Standard Pascal, so they have been placed in their own modules.

For a complete description of DOS operations, refer to a DOS programmer's reference manual.

The primary difference between the *Dos* and *WinDos* units is that the procedures and functions of the *Dos* unit use standard Pascal- *Pascal-style*

||and|
|---|---|
|strings|on|
|page|767.|

style strings and the *WinDos* procedures and functions use null- *nUll-terminated* terminated strings. A standard Pascal-style string is a length byte followed by a sequence of characters. A null-terminated string is a sequence of non-null characters followed by a NULL (#0) character.

|To read|about|the Strings|
|---|---|---|
|unit, see nUll-terminated|Chapter|76, "Using strings.|

Most of the time, you'll probably want to use the *Dos* unit for the programs you write, as most Pascal programs traditionally use *N* the Pascal-style strings. If you also develop applications for the Windows environment, however, you'll be able to write code you can more easily share between the DOS and Windows platforms if you use the *WinDos* unit along with the *Strings* unit; Windows requires the use of null-terminated strings.

You also might want to use the *WinDos* and *Strings* units if you have a C data file you want to use or convert. The C language uses null-terminated strings.

*Chapter* 75, *Interfacing with DOS*

These are the procedures and functions in the *Dos* unit. To use them, you must refer to the *Dos* unit with the **uses** statement in your program.

Table 15.1

**Procedure Description** Dos unit date and time procedures *GetDate* Returns the current date set in the operating system. *GetFTime* Returns the date and time a file was last modified. *GetTime* Returns the current time set in the operating system. *PackTime* Converts a *DateTime* record into a 4-byte, packed date-and-time *Longint* used by *SetFTime.* *SetDate* Sets the current date in the operating system. *SetFTime* Sets the date and time a file was last modified. *SetTime* Sets the current time in the operating system. *UnpackTime* Converts a 4-byte, packed date-and-time *Longint* returned by *GetFTime, FindFirst,* or *FindNext* into an unpacked *DateTime* record.

Table 15.2

**Procedure Description** Dos unit interrupt support procedures *GetIntVec* Returns the address stored in a specified interrupt vector. *Jntr* Executes a specified software interrupt with a specified *Registers* package. *MsDos* Executes a DOS function call with a specified *Registers* package. *SetIntVec* Sets a specified interrupt vector to a specified address.

*Language Guide*

|||15.3|
|---|---|---|
|Dos unit disk|status functions||

**Function Description**

*DiskFree* the number

|Returns||of free bytes|of a specified||
|---|---|---|---|---|
|disk drive.|||||
|Returns drive.|the total|size bytes|of a specified|disk|

*Disksize* in

||Table|15.4||
|---|---|---|---|
|Dos|unit file-handling||Procedure|
|procedures|and functions||or function|

**Description**

|Takes a file||returns a|fully qualified|file|
|---|---|---|---|---|
|(drive, Searches Splits a file|directory, for a file into|name, a list of directories. its three|extension).||
|(drive|directory,|file name,|extension).||
|Searches|the specified|directory|for the first||
|matching attributes. Returns the|the specified next|file that matches|of||
|attributes Returns the Sets the attributes|specified attributes of|a previous of a file. a file.|call|to|

*FExpand* name and name and *Fsearch* in *Fsplit* name component parts and and *FindFirst* entry name and set

*FindNext* entry the name and in *FindFirst.* *GetFAttr* *setFAttr*

Table 15.5

**Function Description** Dos unit environment- handling functions *EnvCount* number in the

|Returns|the|of strings|contained|
|---|---|---|---|
|DOS|environment.|||
|Returns Returns variable.|a specified the value|environment of a specified|string.|

*Envstr* *GetEnv* environment

Table 15.6

**Procedure Description** Dos unit process-handling procedures *Exec* Executes a specified a specified

||program|with|
|---|---|---|
|line.|||
|(or Terminate|Stay Resident) it stay in|terminates memory.|
|all saved vectors.|vectors|the|

command line.

|command|line.||
|---|---|---|
|Keep|||
|program|and makes||
|Swaps|interrupt|with|

*Keep* the

*Swap Vectors* current

*Chapter* 75, *Interfacing with DOS*

||DOS version|number.|||
|---|---|---|---|---|
|Returns|the state of|etr/tBreak|checking|DOS.|
|Returns|the state of|the verify|flag DOS.||
|Sets the|state of etr/-Break|checking|DOS.||
|Sets the|state of the|verify flag|DOS.||

in in in in

##### Dos unit constants, types, and variables

by

|Each of|the constants,|types,|and variables|defined|the|Dos unit|
|---|---|---|---|---|---|---|
|are briefly|discussed|in this|section.|more information, look|||
|them up|in Chapter|I, "Library|reference,"|in the|Programmer's||

For

*Reference.*

##### Constants

The *Dos* unit defines several constants. These constants can be grouped by their function. To learn more about these constants, look them up as part of the group they belong to. For example, to find the value of *FParity,* look up "Flag constants" in the

|||Programmer's|Reference.||||||
|---|---|---|---|---|---|---|---|---|
|Dos unit Table constants|15.8|Constant Flag fmXXXX File attribute|group|Description Used to register Defines Used to|test individual after a call the allowable text file construct|flag to values file attributes|bits the for for use|Flags field of a|

in *Intr* or *MsDos: FCarry,* *FParity, FAuxiliary, FZero, Fsign, FOverfLow* *Mode* *TextRec record:fmClosed,fmlnput,* *fmOutput, fmlnOut* with *FindFirst, GetFAttr,* and *setFAttr: ReadOnly,* *Hidden, sysFile, VolumeID, Directory, Archive,* *AnyFile*

*Language Guide*

##### The Dos unit defines these types:

Table 15.9

**Types Description** Dos unit types File record types *FileRec* defines the internal data format for both typed and untyped files; *TextRec* is the internal format of a variable of type *Text.* *Registers* Variables of this type are used by *Intr* and *MsDos* to specify the input register contents and examine the output register contents of a software interrupt. *DateTime* Variables of this type are used to examine and construct 4-byte, packed date-and-time values for *GetFTime, SetFTime, FindFirst,* and *FindNext.*

*SearchRec* Variables of this type are used by *FindFirst* and *FindNext* to scan directories. File-handling String types used by various procedures and string types functions in the *Dos* unit: *ComStr, PathStr, DirStr,* *NameStr, ExtStr.*

Variables *DosError* is used by many of the routines in the *Dos* unit to report errors.

##### WinDos unit procedures and functions

These are the procedures and functions in the *WinDos* unit. To use them, you must refer to the *WinDos* unit with the **uses** statement in your program:

**Procedure**

|date Table and|15.10 time|Description|||||
|---|---|---|---|---|---|---|
|procedures||Returns Returns Returns Converts date-and-time Sets the Sets the|the current the the current a current|set time a file time set record the operating time a file|the operating last the operating into a 4-byte, system. last modified.|system. modified. system. packed|

WinDos *GetDate* date in *GetFTime* date and was *Get Time* in *PackTime TDateTime* *Longint* used by *SetFTime.* *SetDate* date in *SetFTime* date and was

*Chapter* 75, *Interfacing with DOS*

Table 15.10: WinDos

|date and|time procedures|(continued)|
|---|---|---|
|Sets the|current time|the|
|Converts|a 4-byte,|packed date-and-time record.|

*SetTime* in operating system. *UnpackTime Longint* returned by *GetFTime, FindFirst,* or *FindNext* into an unpacked *TDateTime*

**Procedure Description**

|unit interrupt|support|15.11|
|---|---|---|
||procedures||
|Don't use|these functions||
|when running|Windows|in|
|protected|mode.||

WinDos *GetIntVec*

||the|in||
|---|---|---|---|
|Returns|address vector.|stored|a specified|
|Executes|a specified|software||
|specified||package.||
|Executes|a DOS function package.|call|a specified|
|Sets a address.|specified|vector|to a specified|

interrupt *Intr* interrupt with a *TRegisters* *MsDos* with *TRegisters* *SetIntVec* interrupt

Table 15.12

**Function Description** WinDos unit disk status functions *DiskFree* number

|Returns|the|of free bytes|of a specified||
|---|---|---|---|---|
|disk drive.|||||
|Returns drive.|the total|size bytes|of a specified|disk|

*DiskSize* in

|Table|15.13||
|---|---|---|
|procedures|and|Procedure|
|functions||or function|

File-handling **Description**

*FileExpand* name and returns

|Takes a file||a|fully qualified|file|
|---|---|---|---|---|
|(drive,|directory,||extension).||
|Searches|for a file|a list directories.|||
|Splits a file|into|its|||
|(directory,|file name,|extension).|||
|Searches|the specified|directory|for the first|entry|
|matching attributes.|the specified|file|set of||
|Returns the|next entry|matches|the||
|attributes Returns the Sets the attributes|specified attributes of|a of a file. a file.|call|to|

name name, and *FileSearch* in of *FileSplit* name three component parts and *FindFirst* name and

*FindNext* that name and in previous *FindFirst.* *GetFAttr* *SetFAttr*

*Language Guide*

15.14
WinDos unit directory-**Procedure** handling procedures and **or function Description** functions

|CreateDir|Creates|a new|subdirectory.|||
|---|---|---|---|---|---|
|GetCurDir|Returns|the current||directory|of a specified|
|RemoveDir|Removes|a subdirectory.||||
|SetCurDir|Changes|the|current|directory.||

drive.

Table 15.15

WinDos unit environment- **Function Description** handling functions *GetArgCount* Returns the number of parameters passed to the program on the command line. *GetArgStr* Returns a specified command-line argument. *GetEnvVar* Returns a pointer to the value of a specified environment variable.

Table 15.16

WinDos unit miscellaneous **Procedure** procedures and functions **or function Description**

|DosVersion|Returns|the DOS version|number.|||
|---|---|---|---|---|---|
|GetCBreak|Returns|the state of|Ctrl+Break|checking|in DOS.|
|Get Verify|Returns|the state of|the verify|flag in DOS.||
|SetCBreak|Sets the|state of Ctri+Break|checking|in DOS.||
|Set Verify|Sets the|state of the|verify flag|in DOS.||

##### WinDos unit constants/ types/ and variables

Each of the constants, types, and variables defined by the *WinDos* unit are briefly discussed in this section.

##### Constants

The *WinDos* unit uses several constants. These constants can be grouped by their function. To learn more about these constants, look them up as part of the constant group they belong to. For example, to find the value of *fParity,* look up "Flag constants" in the *Programmer's Reference.*

*Chapter* 15, *Interfacing with DOS*

|Table constants 15.17|Constant|Description|||||
|---|---|---|---|---|---|---|
||Flag fmXXXX faXXXX|Test individual a call to. Used closing Test, set, the|flag file-handling disk clear file-handling|bits file attribute procedures:|Flags register bits connection|after opening|

WinDos **group**

in the *Intr* or *MsDos: fCarry, jParity, fAuxiliary,* *fZero, fSign, fOverflow* by procedures when and *files:fmClosed,fmlnput,* *fmOutput, fmlnOut* and in with *faReadOnly,* *faHidden, faSysFile, fa VolurneID, faDirectory,* *faArchive, faAnyFile* fsXXXX Maximum file-name component string lengths used by *FileSearch* and *FileExpand: fsPathName,* *fsDirectory, fsF ileN arne, fsExtension* fcXXXX Return flags used by the *FileSplit* function: *fcExtension, fcF ileN arne, fcDirectory, fc Wildcards*

##### Types

##### The WinDos unit defines these types:

Table 15.18

**Types Description** WinDos unit types

|File record|TFileRec|is used|for both|typed|and untyped||files;|
|---|---|---|---|---|---|---|---|
||TTextRec|is the|internal|format|of a variable|of|type|
||text.|||||||
|TRegisters|Variables specify output|of this the input register|type are register contents|used contents of a software|by Intr and|and MsDos examine interrupt.|to the|
|TDateTime|Variables of construct GetFTime,|this 4-byte, SetFTime,|type are packed FindFirst,|used date-and-time|to examine and FindNext.|and values|for|
|TSearchRec|Variables FindNext|of this to scan|type are directories.|used|by FindFirst|and||

types

##### Variables

*Dos Error* is used by many of the routines in the *WinDos* unit to report errors.

*Language Guide*

Pascal supports a class of character strings called *null-* *terminated strings.* With Turbo Pascal's extended syntax and the *Strings* unit, your programs can use null-terminated strings by simply referring to the *Strings* unit with the **uses** statement in your program.

#### What is a nUll-terminated string?

The compiler stores a traditional Turbo Pascal **string** type as a length byte followed by a sequence of characters. The maximum length of a Pascal string is 255 characters, and a Pascal string occupies from 1 to 256 bytes of memory.

A null-terminated string has no length byte; instead, it consists of a sequence of non-null characters followed by a NULL (#0) character. There is no inherent restriction on the length of a null- terminated string, but the 16-bit architecture of DOS does impose an upper limit of 65,535 characters.

#### Strings unit functions

Turbo Pascal has no built-in routines specifically for null- terminated string handling. Instead you'll find all such functions in the *Strings* unit. Among them are *StrPCopy,* which you can use

*Chapter* 76, *Using nul/-terminated strings*

to copy a Pascal which you can string. Here's

Strings unit functions **Function**

*StrCat*

*StrComp*

*StrCopy*

*StrECopy*

*StrIComp* *StrLCat*

*StrLComp* *StrLCopy*

*StrEnd*

*StrDispose* *StrLen* *StrLIComp*

*StrLower*

*StrMove*

*StrNew* *StrPas* *StrPCopy*

*StrPos*

string to a null-terminated string, and *StrPas,* use to convert a null-terminated string to a Pascal a brief description of each function:

**Description**

Appends a source string to the end of a, destination string and returns a pointer to the destination string. Compares two strings, Sl and *S2,* and returns a value less than zero if Sl < *S2,* zero if Sl = *S2,* or greater than zero if Sl > *S2.* Copies a source string to a destination string and returns a pointer to the destination string. Copies a source string to a destination string and returns a pointer to the end of the destination string. Compares two strings without case sensitivity. Appends a source string to the end of a destination string, ensuring that the length of the resulting string doesn't exceed a given maximum, and returns a pointer to the destination string. Compares two strings for a given maximum length. Copies up to a given number of characters from a source string to a destination string and returns a pointer to the destination string. Returns a pointer to the end of a string (that is, a pointer to the null character that terminates a string). Disposes of a previously allocated string. Returns the length of a string. Compares two strings for a given maximum length without case sensitivity. Converts a string to lowercase and returns a pointer to the string. Moves a block of characters from a source string to a destination string, and returns a pointer to the destination string. The two blocks may overlap. Allocates a string on the heap. Converts a null-terminated string to a Pascal string. Copies a Pascal string to a null-terminated string and returns a pointer to the null-terminated string. Returns a pointer to the first occurrence of a given substring within a string, or **nil** if the substring doesn't occur within th~ string.

*Language Guide*

16.1: Strings unit functions (continued)
*StrRScan* Returns a pointer to the last occurrence of a given character within a string, or **nil** if the character doesn't occur within the string. *StrScan* Returns a pointer to the first occurrence of a given character within a string, or **nil** if the character doesn't occur within the string. *StrUpper* Converts a string to uppercase and returns a pointer to the string.

#### Using null-terminated strings

Null-terminated strings are stored as arrays of characters with a zero-based integer index type; that is, an array of the form

array[O .. X] of Char

where X is a positive nonzero integer. These arrays are called *zero-based character arrays.* Here are some examples of declarations of zero-based character arrays that can be used to store null-

|terminated|strings:||
|---|---|---|
|type|array[O|15] Chari|
|TFileName|array[O|79] of Chari|
|TMernoText|array[O|1023] of Chari|

Tldentifier = .. of = .. = ..

The biggest difference between using Pascal strings and null- terminated strings is the extensive use of pointers in the manipulation of null-terminated strings. Turbo Pascal performs operations on these pointers with a set of *extended syntax* rules.

##### Character

**pointers and** When extended syntax is enabled, a string literal is *assignment* *compatible* with the *PChar* type. This means that a string literal can **string literals** be assigned to a variable of type *PChar.* For example,

var P: *PChari*

begin P .-'Hello world ... 'i endi

*Chapter* 16, *Using nUll-terminated strings*

The effect of such an assignment is that the pointer points to an area of memory that contains a null-terminated copy of the string literal. This example accomplishes the same thing as the previous example:

const TempString: array[O .. 14] of Char = 'Hello world ... '#O; var P: PChar;

begin P := @TempString; end;

You can use string literals as actual parameters in procedure and function calls when the corresponding formal parameter is of type *PChar.* For example, given a procedure with the declaration

procedure PrintStr(Str: PChar);

##### the following procedure calls are valid:

PrintStr('This is a test'); PrintStr(#10#13);

Just as it does with an assignment, the compiler generates a null- terminated copy of the string literal. The compiler passes a pointer to that memory area in the *Str* parameter of the *PrintStr* procedure.

Finally, you can initialize a typed constant of type *PChar* with a string constant. You can do this with structured types as well, such as arrays of *PChar* and records and objects with *PChar* fields.

const Message: PChar = 'Program terminated';

|Message:|PChar|'Program|terminated';||
|---|---|---|---|---|
|Prompt:|PChar|'Enter|values:||
|Digits:|array[O|9] of|PChar||
|'Zero',|'One',|'Two', 'Seven',|'Three',|'Four', 'Nine');|

= *'i* .. = (

'Five', 'Six', 'Eight',

A string constant expression is always evaluated as a Pascal-style string even if it initializes a typed constant of type *PChar;* therefore, a string constant expression is always limited to 255 characters in length.

*Language Guide*

##### PChar type. This means that

whenever a *PChar* is expected, you can use a zero-based character array instead. When you use a character array in place of a *PChar* value, the compiler converts the character array to a pointer *constant* whose value corresponds to the address of the first element of the array. For example,

var A: array[O .. 63) of Char; P: PChar;

begin P := A; PrintStr(A}; PrintStr(P}; end;

Because of this assignment statement, P now points to the first element of *A,* so *PrintStr* is called twice with the same value.

You can initialize a typed constant of a zero-based character array type with a string literal that is shorter than the declared length of the array. The remaining characters are set to NULL (#0) and the string.

|array effectively|contains|a null-terminated|
|---|---|---|
|type|||
|TFileName|array[O|79) of Char;|
|FileNameBuf:|TFileNarne|'TEST.PAS';|
|FileNarnePtr:|PChar|FileNarneBuf;|

##### = ..

const = =

Just as a zero-based character array is compatible with a character pointer, so can a character pointer be indexed as if it were a zero- based character array.

var A: array[O .. 63) of Char; P: PChar; Ch: Char;

*Chapter* 76, *Using nUll-terminated strings*

*PfO]* is equivalent to pA and specifies the character pointed to by P. *P[ll* specifies the character right after the one pointed to by P, *P[2]* specifies the next character, and so on. For

|indexing,|a behaves|if it were|
|---|---|---|
|type|||
|TCharArray PChar|array[0 ATCharArray;|of Char;|

*PChar* as declared as this:

= .. 65535] =

The compiler performs no range checks when indexing a char- acter pointer because it has no type information available to determine the maximum length of the null-terminated string pointed to by the character pointer. Your program must perform any such range checking.

The *StrUpper* function shown here illustrates the use of character pointer indexing to convert a null-terminated string to uppercase.

function StrUpper(Str: PChar): PChar; var I: Word; begin I : = 0; while Str[I] <> #0 do

|while|<>|#0 do||
|---|---|---|---|
|begin||||
|Str [I] Inc end; StrUpper end;|: = UpCase := Str;|(Str[I]|);|

(I);
Notice that *StrUpper* is a function, not a procedure, and that it always returns the value that it was passed as a parameter. Because the extended syntax allows the result of a function call to be ignored, *StrUpper* can be treated as if it were a procedure:

StrUpper (A); PrintStr (A);

*Language Guide*

PrintStr(StrUpper(A));

**Nesting calls to null-terminated string-handling functions can be very convenient when you want to indicate a certain interrelation-**

##### ship between a set of sequential string manipulations.

#### ~ For information about PChar operations, see page 71.

##### Null-terminated strings and

|Turbo Pascal's|extended|syntax|allows|the Read,|Readln, Str,|and|
|---|---|---|---|---|---|---|
|Val standard|procedures|to be|applied|to zero-based|character||
|arrays, and|allows|the Write, Writeln,|Val,|Assign,|and Rename||
|standard|procedures|to be applied|to both|zero-based|character||
|arrays and|character|pointers.|For more|details,|see the descrip-||
|tions of|these standard|procedures|in the|Programmer's|Reference.||

**standard procedures**

**An example using string-handling Here's a code example that shows how we used some of the**

**functions** **string-handling functions when we wrote the *FileSplit* function in the *WinDos* unit:**

file string

|{Maximum|name component||lengths|||
|---|---|---|---|---|---|
|const||||||
|fSPathName|79;|||||
|fsDirectory|67;|||||
|fsFileName|8;|||||
|fsExtension const|4; return flags|||||
|fcExtension|$0001;|||||
|fcFileName|$0002;|||||
|fcDirectory|$0004;|||||
|fcWildcards|$0008; the|name specified|by Path|into||
|three components.|Dir|to the|drive and|directory|path|
|{with any|leading and|backslashes,|Name||to the|
|{name,|and Ext|to the extension|with|a preceding||
|{period.|a component|parameter|NIL,|the||
|{corresponding|part of|the path|not stored.|the path||
|{does not|contain a given|component,|the returned|component||
|{|empty. The|lengths|of the strings|returned||

= = = =

FileSplit

= = = =

FileSplit splits file its is set trailing is set file is set If string is is If

string is maximum

***Chapter* 76, *Using nul/-terminated strings***

StrRScan(Path, '\');

|NamePtr|= then|:= StrRScan(Path,|||
|---|---|---|---|---|
|NamePtr|= then|:= Path||Inc (NamePtr)|
|ExtPtr := StrScan(NamePtr,||,|||
|ExtPtr = DirLen := NamePtr|then ExtPtr -Path;|:= StrEnd(NamePtr);|||
|DirLen > NameLen :=|fsDirectory ExtPtr-NamePtr;|then DirLen|:= fsDirectory;||
|NameLen Flags := 0;|> fSFilenarne|then NameLen|fsFilename;||
|(StrScan(NamePtr, (StrScan(NamePtr, Flags :=|fcWildcards;|<> nil) <> nil) then|or||
|DirLen <>|0 then Flags|:= Flags|or fcDirectory;||
|NameLen|<> 0 then Flags|:= Flags|or fcFilename;||
|ExtPtr[O]|<> #0 then|Flags := Flags|or fcExtension;||
|Dir <>|then StrLCopy(Dir,|Path,|DirLen);||
|Name <>|then StrLCopy(Name,||NamePtr,|NameLen);|
|Ext <>|then StrLCopy(Ext, Flags;|ExtPtr,|fsExtension);||

**if** NamePtr = **nil then** NamePtr := StrRScan(Path, ': '); **if nil** NamePtr **else**; .'); **if nil**

**if**

**if** .-

**if** '?') '*')

**if if**

##### if if nil

##### if nil if nil

FileSplit .- **end;**

***Language Guide***

#### Using the Borland Graphics Interface

|The Graph|unit features|a complete|library|of more|than 50||
|---|---|---|---|---|---|---|
|graphics|routines|that range|from high-level|calls|such as||
|Set ViewPort,|Circle,|Bar3D, and|DrawPoly,|to bit-oriented|routines||
|such as|GetImage|and PutImage.|supports|several|fill and line||
|styles and|there are|several fonts|that may|be magnified,|justified,||
|and oriented|horizontally|or|vertically.||||
|To compile|a program|that uses|the Graph|unit, you'll|need|your|
|program's|source|code, the|and|access to|the standard||
|units in (GRAPH.TPU):|the run-time|library|(TURBO.TPL)|and the|Graph unit||
|To|a program|that uses the|Graph unit,|you'll need|one|or|
|more of|the graphics|drivers|(.BGI files|listed in the|next section)||
|in addition|to your|.EXE program.|Also,|if your program|uses|any|
|stroked|fonts, you'll|need one|or more|font (.CHR)|files as well.||

It

|Your|license agreement||
|---|---|---|
|permits|you to distribute|the|
|.CHR and|.BGI files along your programs.|with|

compiler~

run

#### Drivers

Graphics drivers are provided for the following graphics adapters (and true compatibles):

##### .CGA • Hercules

- MCGA • AT&T 400 line
- EGA .3270 PC .VGA • IBM
*Chapter* 77, *Using the Borland Graphics Interface*

Each driver contains code and data and is stored in a separate file on disk. At run time, the *InitGraph* procedure identifies the graphics hardware, loads and initializes the appropriate graphics driver, puts the system into graphics mode, and then returns control to the calling routine. The *CloseGraph* procedure unloads the driver from memory and restores the previous video mode. You can switch back and forth between text and graphics modes using the *RestoreCrtMode* and *SetGraphMode* routines. To load the driver files yourself or link them into your .EXE file, refer to *RegisterBGldriver* in Chapter I, "Library reference," in the *Programmer's Reference.*

*Graph* supports computers with dual monitors. When *Graph* is

initialized by calling *InitGraph,* the correct monitor will be selected for the graphics driver and mode requested. When terminating a graphics program, the previous video mode will be restored. If auto detection of graphics hardware is requested on a dual moni- tor system, *InitGraph* will select the monitor and graphics card that will produce the highest quality graphics output.

|BGI drivers 17.1|Driver|Equipment||
|---|---|---|---|
||ATT.BGI|AT&T|6300 (400|
||CGA.BGI|IBM CGA,||
||EGAVGA.BGI HERC.BGI|IBM EGA,|VGA|
||IBM8514.BGI|IBM 8514||
||PC3270.BGI|IBM 3270|PC|

line) MeGA

Hercules monochrome

##### IBM 8514 support

Turbo Pascal supports the IBM 8514 graphics card, a high- resolution graphics card capable of resolutions up to 1024 x 768 pixels and a color palette of 256 colors from a list of 256K colors .. The driver file name is IBM8514.BGI.

Turbo Pascal can't properly autodetect the IBM 8514 graphics card (the autodetection logic recognizes it as VGA). Therefore, to use the IBM 8514 card, the *GraphDriver* variable must be assigned the value IBM8514 (which is defined in the *Graph* unit) when *InitGraph* is called. You should not use *DetectGraph* (or *Detect* with *InitGraph)* with the IBM 8514 unless you want the emulated VGA mode.

The supported modes of the IBM card are IBM8514LO (640 x pixels), and IBM8514HI (1024 x pixels). Both mode

*Language Guide*

constants are defined in the interface for GRAPH. TPU or GRAPH.TPP.

The IBM 8514 uses three 6-bit values to define colors. There is a 6-bit Red, Green, and Blue component for each defined color. The *SetRGBPalette* procedure allows you to define colors for the IBM 8514; it's defined in the *Graph* unit as:

procedure SetRGBPalette(ColorNum, Red, Green, Blue: Word);

The argument *ColorNum* defines the palette entry to be loaded. *ColorNum* is an integer from 0 to 255 (decimal). The arguments *Red, Green,* and *Blue* define the component colors of the palette entry. Only the lower byte of these values is used, and out of this byte, only the 6 most-significant bits are loaded in the palette.

The other palette manipulation routines of the graphics library can't be used with the IBM 8514 driver (that is, *SetAllPalette,* *SetPalette,* and *GetPalette).*

For compatibility with the balance of the IBM graphics adapters, the BGI driver defines the first 16 palette entries of the IBM 8514 to the default colors of the EGAjVGA. These values can be used as is, or changed using the *SetRGBPalette* routine.

|By convention,|the upper|left corner|of the graphics|screen|is (0,0).|
|---|---|---|---|---|---|
|The values,|or columns,|increment|to the right.|The values,|or|
|rows, increment|downward.|320x200|mode|on a|the|
|screen coordinates|for|each of the|four corners|with a specified||
|point in|middle of|the screen|would look|like this:||

*x y* In eGA,

the

Screen with xv-coordinates (0,0) (319,0) ~----------------~

.(159,99)
(0,199) (319,199)

*Chapter* 77, *Using the Borland Graphics Interface*

80 on the 25th line, the entire screen scrolls up one line, and the cursor is in column 1 of line 25.

MoveTo(O,O) LineTo(20,20)

In graphics mode, the preceding *LineTo* statement leaves the CP at the last point referenced (20,20). The actual line output is clipped to the current viewport if clipping is active. Note that the CP is never clipped.

The *MoveTo* command is the equivalent of *GoToXY.* Its only purpose is to move the CPo Only the commands that *use* the CP *move* the CP: *InitGraph, MoveTo, MoveRel, LineTo, LineRel, OutText,* *SetGraphMode, GraphDefaults, ClearDevice, Set ViewPort,* and *Clear ViewPort.* The latter five commands move the CP to (0,0).

several

|An 8x8|bitmapped|font and|stroked|fonts are|included|for|
|---|---|---|---|---|---|---|
|text output|while|in graphics|mode. A bitmapped|character||is|
|defined|8x8|matrix of|A stroked|font is|defined|a|
|series of font.|vectors|that tell the|system|to|draw the||
|The advantage|of|using a stroked|font is||you|start|
|to draw|large characters.|Because|a stroked|font is defined|||
|vectors, enlarged.|it retains|good resolution|and quality||the font|is|
|When|a bitmapped|font is enlarged,|the|is multiplied|||
|a scaling|factor|and, as the|scaling factor|becomes|larger,|the|

##### by an pixels. by

graphics how

apparent when by when

matrix by

*Language Guide*

##### OutTextXY procedures. Inquiries about the current text settings

are made by calling the *GetTextsettings* procedure. The size of stroked fonts can be customized by the *setUserCharsize* procedure.

Each stroked font is kept in its own file on disk with a .CHR file extension. Font files can be loaded from disk automatically by the

*Graph* unit at run time (as described), or they can be linked in or

loaded by the user program and "registered" with the *Graph* unit.

Turbo Pascal provides a special utility, BINOBJ.EXE, that converts a font file (or any binary data file, for that matter) to an .OBJ file that can be linked into a unit or program using the {$L} compiler directive. This makes it possible for a program to have all its font files built into the .EXE file. (Read the comments at the beginning of the BGILINK.PAS sample program.)

#### Figures and styles

All kinds of support routines are provided for drawing and filling figures, including points, lines, circles, arcs, ellipses, rectangles, polygons, bars, 3-D bars, and pie slices. Use *setLinestyle* to control whether lines are thick or thin, or whether they are solid, dotted, or built using your own pattern.

Use *setFillstyle* and *setFillPattern, FillPoly* and *FloodFill* to fill a region or a polygon with cross-hatching or other intricate patterns.

##### Viewports and bit

images The *Set ViewPort* procedure makes all output commands operate in a rectangular region onscreen. Plots, lines, figures-all graphics output-are viewport-relative until the viewport is changed. Other routines are provided to clear a viewport and read the current viewport definitions. If clipping is active, all graphics

*Chapter* 77, *Using the Borland Graphics Interface*

CP is never clipped.

*GetPixel* and *PutPixel* are provided for reading and plotting pixels. *GetImage* and *PutImage* can be used to save and restore rectan- gular regions onscreen. They support the full complement of *BitBIt* operations (copy, **xor, or, and, not).**

#### Paging and colors

There are many other routines that support palettes, colors, multiple graphic pages (EGA, VGA, and Hercules only), and soon.

#### Error handling

Internal errors in the *Graph* unit are returned by the function *GraphResuIt. GraphResuIt* returns an error code that reports the status of the last graphics operation. Find the error return codes under GraphResult Errors in Chapter I, "Library reference," in the *Programmer's Reference.*

##### The following routines set GraphResuIt:

##### Bar ImageSize SetF illPattern

##### Bar3D InitGraph SetF illS tyle

##### ClearViewPort Install User Driver SetGraphBufSize

##### CloseGraph InstallUserFont SetGraphMode

##### DetectGraph PieS lice SetLineStyle

##### DrawPoly Regis terB Gldriver SetPalette

##### FillPoly RegisterBGIfont SetTextJustify

##### FloodFill SetAllPalette SetTextStyle

*GetGraphMode*

*GraphResuIt* is reset to zero after it has been called. Therefore, the user should store the value of *GraphResuIt* into a temporary variable and then test it.

*Language Guide*

S = 'Borland Graphics Interface (BGI) '; **var** GraphDriver: Integer; GraphMode: Integer; ErrorCode: Integer; Size: Word; **begin** GraphDriver := Detect; { Set flag: do detection} InitGraph(GraphDriver, GraphMode, 'C:\TP\BGI'); ErrorCode := GraphResult; **if** ErrorCode <> GrOk **then** Error? } **begin** Writeln('Graphics error: ' GraphErrorMsg(ErrorCode)); Writeln('Program aborted ... '); Halt (1); **end;** Rectangle (0, 0, GetMaxX, GetMaxY); Draw full sceen box } SetTextJustify(CenterText, CenterText); { Center text } Size := 3; **repeat** SetTextStyle(DefaultFont, HorizDir, Size); Dec(Size); **until** (Size = 0) **or** (TextWidth(S) < GetMaxX); **if** Size <> 0 **then** OutTextXY(GetMaxX **div** 2, GetMaxY **div** 2, S); Center of screen } Readln; CloseGraph; **end.** { GrafTest

**The program begins with a call to** *In it Graph,* **which autodetects** **the hardware and loads the appropriate graphics driver. For the** **program to run correctly, the driver and fonts must be in the same** **directory as the executable program, or the program must specify** **an explicit directory. In this example, the directory is C:\ TP\BGI.** **If the program fails to recognize graphics hardware or an error occurs during initialization, the program displays an error**

##### message and terminates. Otherwise, the program draws a box

##### along the edge of the screen and displays text in the center of the screen.

***Chapter* 77, *Using the Borland Graphics Interface***

#### ~ Neither the AT&T 400 line card nor the IBM 8514 graphics

##### adapter is autodetected. You can still use these drivers by over-

**riding autodetection and passing *InitGraph* the driver code and a valid graphics mode. To use the AT&T driver, for example,**

##### replace the ninth and tenth lines in the preceding example with of code:-

|the following|three lines|
|---|---|
|GraphDriver|:= ATT400;|
|GraphMode InitGraph(GraphDriver,|:= ATT400Hi;|

GraphMode, 'C:\TP\BGI');

**This instructs the graphics system to load the AT&T 400 line** **driver located in C: \ TP\BGI and set the graphics mode to 640 by**

**400.** **Here's another example that demonstrates how to switch back and forth between graphics and text modes:** **program** GrafTst2; **uses** Graph; **var** GraphDriver: Integer; GraphMode: Integer; ErrorCode: Integer; **begin** GraphDriver := Detect; { Set flag: do detection} InitGraph(GraphDriver, GraphMode, 'C:\TP\BGI'); ErrorCode := GraphResult; **if** ErrorCode <> grOk **then** { Error? } **begin** Writeln('Graphics error: " GraphErrorMsg(ErrorCode)); Writeln('Program aborted ... '); Halt (1); **end;** OutText('In Graphics mode. Press <RETURN>'); Readln; RestoreCRTMode; Write('Now in text mode. Press <RETURN>'); Readln; SetGraphMode(GraphMode); OutText('Back in Graphics mode. Press <RETURN>'); Readln; CloseGraph; **end.** { GrafTst2
***Language Guide***

P: Pointer; Size: Word); { Allocate memory for graphics }

|{Allocate|memory|for graphics||}|||
|---|---|---|---|---|---|---|
|procedure|GraphFreeMem(var||P:|Pointer;|Size:|Word);|
|{Deallocate|memory|for|graphics|}|||

Two pointers are defined by *Graph* that, by default, point to the two standard routines described here. The pointers are defined as follows:

var GraphGetMemPtr: Pointer; { Pointer to memory allocation routine }

|GraphGetMemPtr:|Pointer;|{Pointer|to memory|allocation|routine|}|
|---|---|---|---|---|---|---|
|GraphFreeMemPtr:|Pointer|Pointer|to memory|deal location|routine|}|

The *Graph* unit calls the heap management routines referenced by *GraphGetMemPtr* and *GraphFreeMemPtr* to allocate and deallocate memory for three different purposes:

- A multi-purpose graphics buffer whose size can be set by a call to *SetGraphBujSize* (default equals *4K)*
- A device driver that is loaded by *InitGraph* (*.BGI files)
- A stroked font file that is loaded by *SetTextStyle* (*.CHR files) The graphics buffer is always allocated on the heap. The device driver is allocated on the heap unless your program loads or links one in and calls *RegisterBGldriver.* The font file is allocated on the heap when you select a stroked font using *SetTextStyle-unless* your program loads or links one in and calls *RegisterBGIfont.* When the *Graph* unit is initialized, these pointers point to the standard graphics allocation and deallocation routines that are defined in the implementation section of the *Graph* unit. You can
*Chapter* 77, *Using the Borland Graphics Interface*

P: Pointer; Size: **Word); far;** { Allocate memory for graphics device drivers, fonts, and scan buffer} **begin** GetMem(P, Size) **end;** { MyGetMem }

**procedure** MyFreeMem(var P: Pointer; Size: **Word); far;** { Deallocate memory for graphics device drivers, fonts, and scan buffer} **begin** **if** P <> **nil then** { Don't free nil pointers! } **begin** FreeMem(P, Size); P **:= nil;** **end;** **end;** { MyFreeMem

**procedure** MyExitProc; **far;** { Always gets called when program terminates **begin** ExitProc **:=** PreGraphExitProc; Restore original exit proc CloseGraph; { Do heap clean up **end;** { MyExitProc }

**begin** Install clean-up routine PreGraphExitProc **:=** ExitProc; ExitProc **:=** @MyExitProc;

GraphGetMemPtr :=.@MyGetMem; { Control memory allocation GraphFreeMemPtr **:=** @MyFreeMem; Control memory deallocation

***Language Guide***

");

|ErrorCode|:= GraphResult;|||
|---|---|---|---|
|ErrorCode begin|<> grOk|then||
|Writeln('Graphics Readlni Halt (1); end;||error:|' GraphErrorMsg(ErrorCode))i|
|Line(O,|0, GetMaxX,|GetMaxY);||
|OutTextXY(1, Readlni end. {UserHeapManagement}|1, 'Press|<Return>:');||

if

**procedures**

#### Graph

Table 17.2: Graph unit

*Arc* *Bar* *Bar3D* *Circle* *ClearDevice* *Clear ViewPort* *CloseGraph* *DetectGraph* *DrawPoly* *Ellipse*

*FillEllipse*

*FillPoly* *FloodFill* *GetArcCoords* *GetAspectRatio*

*GetBkColor* *GetColor*

**and functions**

The *Graph* unit provides many procedures and functions for use in your programs:

procedures and functions

Draws a circular arc from start angle to end angle using *(x,y)* as the center point. Draws a bar using the current fill style and color. Draws a 3-D bar using the current fill style and color. Draws a circle using *(x,y)* as the center point. Clears the currently selected output device and homes the current pointer. Clears the current viewport. Shuts down the graphics system. Checks the hardware and determines which graphics driver and mode to use. Draws the outline of a polygon using the current line style and color. Draws an elliptical arc from start angle to end angle, using *(x,y)* as the center point. Draws a filled ellipse using *(x,y)* as a center point and *XRadius* and *YRadius* as the horizontal and vertical axes. Fills a polygon, using the scan converter.. Fills a bounded region using the current fill pattern and fill color. Allows the user to inquire about the coordinates of the last *Arc* command. Returns the effective resolution of the graphics screen from which the aspect ratio *(Xasp:Yasp)* can be computed. Returns the current background color. Returns the current drawing color.

*Chapter* 77, *USing* *the Borland Graphics Interface*

17.2: Graph unit procedures and functions (continued)

|GetDefauItPalette|Returns|the default|hardware|palette in a|record of PaletteType.||||
|---|---|---|---|---|---|---|---|---|
|GetDriverName|Returns|a string containing|the|name of the|current driver.||||
|GetFillPattern|Returns|the last fill|pattern set|by a call to|SetFillPattern.||||
|GetFillSettings|Allows SetFillStyle|the user to or SetFillPattern.|inquire about|the current|fill pattern|and color|as set|by|
|GetGraphMode|Returns|the current|graphics mode.||||||
|GetImage|Saves|a bit image|of the specified|region into|a buffer.||||
|GetLineSettings|Returns SetLineStyle.|the current|line style,|line pattern,|and line thickness|as|set by||
|GetMaxColor|Returns|the highest|color that|can be passed|to SetColor.||||
|GetMaxMode|Returns|the maximum|mode number|for|the currently|loaded driver.|||
|GetMaxX|Returns|the rightmost|column|(x resolution)|of the current|graphics|driver|and|
||mode.||||||||
|GetMaxY|Returns|the bottommost|row|(y resolution)|of the current|graphics|driver|and|
||mode.||||||||
|GetModeName|Returns|a string containing|the|name of the|specified|graphics|mode.||
|GetModeRange|Returns|the lowest|and highest|valid graphics|mode|for a given|driver.||
|GetPaletteSize|Returns|the size of|the palette|color lookup|table.||||
|GetPixel|Gets the|pixel value|at (x,y).||||||
|GetPalette|Returns|the current|palette and|its size.|||||
|GetTextSettings|Returns SetTextStyle|the current and SetTextJustify.|text font,|direction, size,|and justification|as|set by||
|GetViewSettings|Allows|the user to|inquire about|the current|viewport|and clipping|parameters.||
|GetX|Returns|the x-coordinate|of the|current position|(CP).||||
|GetY|Returns|the y-coordinate|of the|current position|(CP).||||
|GraphDefaults|Homes|the current|pointer (CP)|and resets|the graphics|system.|||
|GraphErrorMsg|Returns|an error message|string|for the specified|ErrorCode.||||
|GraphResuIt|Returns|an error code|for the|last graphics|operation.||||
|ImageSize|Returns|the number|of bytes required|to|store a rectangular|region|of the|screen.|
|InstallUserDriver|Installs|a vendor-added|device|driver to|the BGI device|driver|table.||
|InstallUserFont|Installs|a new font|file that isn't|built into|the BGI system.||||
|InitGraph|Initializes|the graphics|system|and puts the|hardware|into graphics|mode.||
|Line|Draws|a line from|the (xl, yl)|to (x2, y2).|||||
|LineRel|Draws|a line to a point|that is|a relative distance|from|the current|pointer|(CP).|
|LineTo|Draws|a line from|the current|pointer to|(x,y).||||

*Language Guide*

||||(CP) a relative|distance|from its|current position.|
|---|---|---|---|---|---|---|
|MoveTo|Moves the|current graphics|pointer|(CP) to (x,y).|||
|OutText|Sends a string|to the output|device|at the current|pointer.||
|OutTextXY|Sends a string|to the output|device.||||
|PieS lice|Draws and angle to end|fills a pie slice, angle.|using (x,y)|as the center|point and|drawing|
|PutImage|Puts a bit image|onto the|screen.||||
|PutPixei|Plots a pixel|at (x,y).|||||
|Rectangle|Draws a rectangle|using|the current|line style and|color.||
|RegisterBGldriver|Registers a|valid BGI driver|with the|graphics system.|||
|RegisterBGIfont|Registers a|valid BGI font|with the|graphics system.|||
|RestoreCrtMode|Restores the|original screen|mode before|graphics|is initialized.||
|Sector|Draws and|fills an elliptical|sector.||||
|SetActivePage|Sets the active|page for|graphics output.||||
|SetAllPalette|Changes all|palette colors|as specified.||||
|SetAspectRatio|Changes the|default aspect|ratio.||||
|SetBkCoior|Sets the current|background|color using|the palette.|||
|SetColor|Sets the current|drawing|color using|the palette.|||
|SetFillPattern|Selects a user-defined|fill|pattern.||||
|SetFillStyle|Sets the fill|pattern and|color.||||
|SetGraphBujSize|Lets you change|the size|of the buffer|used for|scan and flood|fills.|
|SetGraphMode|Sets the system|to graphics|mode and|clears the|screen.||
|SetLineStyle|Sets the current|line width|and style.||||
|SetPalette|Changes one|palette color|as specified|by ColorNum|and Color.||
|SetRGBPalette|Lets you modify|palette|entries for|the IBM 8514|and the VGA|drivers.|
|SetTextJustify|Sets text justification|values|used by|OutText and|OutTextXY.||
|SetTextStyle|Sets the current|text font,|style, and|character magnification||factor.|
|SetUserCharSize|Lets you change|the character|width|and height|for stroked|fonts.|
|SetViewPort|Sets the current|output|viewport or|window for|graphics|output.|
|SetVisualPage|Sets the visual|graphics|page number.||||
|SetWriteMode|Sets the writing|mode (copy|or xor)|for lines drawn|by DrawPoly,|Line,|
||Line To, and|Rectangle.|||||
|TextHeight|Returns the|height of a|string in pixels.||||
|Text Width|Returns the|width of a string|in pixels.||||

from start

*LineRel,*

*Chapter* 77, *Using the Borland Graphics Interface*

##### I, "Library reference," in the Programmer's Reference.

**Graph unit constants, types, and variables**

The *Graph* unit defines several constants, types, and variables that your programs can use.

##### Constants

|The|Graph|constants|can|be|grouped|by|their|function.|To|learn|
|---|---|---|---|---|---|---|---|---|---|---|
|more|about|these|constants,||see Chapter||I,|"Library|reference,"|in|
|the|Programmer's||Reference.||Look|up the|constant|under|the|group|
|it belongs want:||to. This|table|will|help|you identify||the group||you|
||Constant|group|||Description||||||

Table 17.3

Graph unit constant groups

Driver and mode Constants that specify video drivers and modes; used with *InitGraph, DetectGraph,* and *GetModeRange.* grXXXX Constants that identify the type of error returned from *GraphResult.* Color Constants that specify colors; used with *setPalette* and *setAllPalette.* Color for *setRGBPalette* Constants used with *setRGBPalette* to select standard EGA colors on an IBM 8514. Line style Constants used to determine a line style and thickness; used with *GetLinesettings* and *setLinestyle.* Font control Constants that identify fonts; used with *GetTextsettings* and *setTextstyle.* Justification Constants that control horizontal and vertical justification; used with *setTextJustify.* Clipping Constants that control clipping; used with *Set ViewPort.* Bar Constants that control the drawing of a 3-D top on a bar; used with *Bar3D.* Fill pattern Constants that determine the pattern used to fill an area; used with *GetFillsettings* and *setFillstyle.*

*Language Guide*

|Table 17.3:|Graph|unit constant|
|---|---|---|
|BitBlt|||

groups (continued)

operators Operators (copy, **xor,** or, **and,** and **not)** used with *PutImage* and, *SetWriteMode.* MaxColors The constant that defines the maximum number of colors used with *GetPalette,* *GetDefaultPalette,* and *SetAIIPalette.*

For example, to find the constant you need to change the background screen color to green, look under Color Constants in Chapter I, "Library reference," in the *Programmer's Reference.*

##### The Graph unit defines these types:

**Type Description**

|PaletteType|The record|that defines|the size.and|colors|
|---|---|---|---|---|
||of the palette; GetDefaultPalette,|used by and|GetPalette, SetAIIPalette.||
|LineSettingsType|The record and thickness GetLineSettings.|that defines of a line;|the style, used by|pattern,|
|TextSettingsType|The record GetTextSettings.|that defines|the text;|used by|
|FillSettingsType|The record color used GetFillSettings.|that defines to fill an area;|the pattern used|and by|
|FillPa ttern|The record pattern; used SetFillPattern.|that defines by GetFillPattern|a user-defined|fill and|
|PointType|A type defined|for your|convenience.||
|ViewPort|A record current viewport;|that reports used|the status by GetViewSettings.|of the|
|ArcCoordsType|A record the last call|that retrieves to Arc or|information Ellipse; used|about by|

*Type*

*Type*

*GetArcCoords.*

##### Variables

The *Graph* unit has two variables you can use: *GraphGetMemPtr* and *GraphFreeMemPtr.* They are used by heap-management routines. Read about them in Chapter I, "Library reference," in the *Programmer's Reference.*

*Chapter* 17, *Using the Bor/and Graphics Interface*

*Language Guide*

##### A p T E R

**18**

#### Using overlays

*Overlays* are parts of a program that share a common memory area. Only the parts of the program that are required for a given function reside in memory at the same time; they can overwrite each other during execution.

Overlays can significantly reduce a program's total run-time memory requirements. In fact, with overlays you can execute pro- grams that are much larger than the total available memory because only parts of the program reside in memory at any given time.

Turbo Pascal manages overlays at the unit level; this is the smallest part of a program that can be made into an overlay. When an overlaid program is compiled, Turbo Pascal generates an overlay file (extension .OVR) in addition to the executable file (extension .EXE). The .EXE file contains the static (nonoverlaid) parts of the program, and the .OVR file contains all the overlaid units that will be swapped in and out of memory during program execution.

Except for a few programming rules, an overlaid unit is identical to a nonoverlaid unit. In fact, as long as you observe these rules, you don't even need to recompile a unit to make it into an over- lay. The decision of whether or not a to overlay a unit is made by the program that uses the unit.

When an overlay is loaded into memory, it's placed in the overlay buffer, which resides in memory between the stack segment and the heap. By default, the size of the overlay buffer is as small as

*Using overlays*

DOS ("Program too big to fit in memory") or by the. IDE ("Not enough memory to run pro- gram").

One very important option of the overlay manager is the ability to load the overlay file into expanded memory when sufficient space is available. Turbo Pascal supports version 3.2 or later of the Lotus/Intel/Microsoft Expanded Memory Specification (EMS) for this purpose. Once placed into EMS, the overlay file is closed, and subsequent overlay loads are reduced to fast in-memory transfers.

#### The overlay manager

Turbo Pascal's overlay manager is implemented by the *Overlay* standard unit. The buffer-management techniques used by the *Overlay* unit are very advanced, and always guarantee optimal performance in the available memory. For example, the overlay manager always keeps as many overlays as possible in the over- lay buffer to reduce the chance of having to read an overlay from disk. Once an overlay is loaded, a call to one of its routines exe- cutes just as fast as a call to a nonoverlaid routine. Also, when the overlay manager needs to dispose of an overlay to make room for another, it attempts to first dispose of overlays that are inactive (ones that have no active routines at that time).

To implement its advanced overlay-management techniques, Turbo Pascal requires that you observe two important rules when writing overlaid programs:

- All overlaid units must include a **{$O+}** directive, which causes the compiler to ensure that the generated code can be overlaid.
- Whenever a call is made to an overlaid procedure or function, you must ensure that all currently active procedures and functions use the far call model. Both rules are explained further in a section entitled "Designing overlaid programs," beginning on page 197. For now, just note that you can easily satisfy these requirements by placing a **{$O+,F+}** compiler directive at the beginning of all overlaid units,
*Language Guide*

and a **{$F+}** compiler directive at the beginning of all other units and the main program.

Failing to observe the far call requirement in an overlaid program causes unpredictable and possibly catastrophic results when the program is executed.

The **{SO** *unitname}* compiler directive is used in a program to indicate which units to overlay. This directive must be placed after the program's **uses** clause, and the **uses** clause must name the *Overlay* standard unit before any of the overlaid units. Here is an example:

program Editor;

||||calls|all||&|
|---|---|---|---|---|---|---|
|{$F+}||{Force|FAR|for|procedures|functions|
|Overlay, {SO EdlnOut} {SO EdFormat} {SO EdPrint} {SO EdFind} {SO EdMatn}|Crt,|Dos, EdInOut,|EdFormat,|EdPrint,|EdFind,|EdMain;|

uses

|The compiler|reports|error|you attempt|to overlay|a unit|that|
|---|---|---|---|---|---|---|
|wasn't|compiled in|the {$O+}|state. Of the|standard|units, the|only|
|one that|can be overlaid|is Dos;|the other|standard|units, can't|be|
|overlaid.|Also, programs|containing|overlaid|units|must be||
|compiled compile|to disk; such programs|the compiler to memory.|reports an|error you|attempt|to|

an if

if

**buffer**

**management** The Turbo Pascal overlay buffer is best described as a ring buffer that has a head pointer and a tail pointer. Overlays are always loaded at the head of the buffer, pushing" older" ones toward the tail. When the buffer becomes full (that is, when there isn't enough free space between the head and the tail), overlays are disposed of at the tail to make room for new ones.

Because ordinary memory isn't circular in nature, the actual implementation of the overlay buffer involves a few more steps to make the buffer appear to be a ring. Figure 18.1 illustrates the process. The figure shows a progression of overlays being loaded into an initially empty overlay buffer. Overlay *A* is loaded first, followed by B, then C, and finally *D.* Shaded areas indicate free buffer space.

*Chapter* 78, *Using overlays*

overlays

Head

|Overlay|B|
|---|---|
|Overlay|A|
|Step|4|
|Overlay|C|
|Overlay|B|
|Overlay|D|

Head Overlay A

||Overlay|A||
|---|---|---|---|
|Tail Hea d|Step|3|Tail|
||Overlay|C||
||Overlay|B|Tail|
||||Hea d|
|Tail|Overlay|A||

......

As you can see, a couple of interesting things happen in the transition from step 3 to step 4. First, the head pointer wraps around to the bottom of the overlay buffer, causing the overlay manager to slide all loaded overlays (and the tail pointer) upward. This sliding is required to keep the area between the head pointer and the tail pointer free. Second, to load overlay D, the overlay manager has to dispose of overlay *A* from the tail of the buffer. Overlay *A* in this case is the least recently loaded over- lay and, therefore, the best choice for disposal when something. has to go. The overlay manager continues to dispose of overlays at the tail to make room for new ones at the head, and each time the head pointer wraps around, the sliding operation repeats.

Although this is the default mode of operation for Turbo Pascal's overlay manager, you can use an optional optimization of the overlay-management algorithm.

Imagine that overlay *A* contains a number of frequently used routines. Even though these routines are used all the time, *A* is still thrown out of the overlay buffer occasionally, only to be reloaded again shortly thereafter.

The overlay manager knows nothing about the *frequency* of calls to routines in *A-only* that a call is made to a routine in *A* and *A* isn't in memory, so it has to load *A.* One solution to this problem

*Language Guide*

On the other hand, if no calls are made to an overlay during its probationary period, thereby indicating infrequent use, the over- lay is disposed of when it reaches the tail of the overlay buffer.

The net effect of the probation/ reprieval scheme is that frequently used overlays are kept in the overlay buffer at the cost of intercep- ting just *one* call every time the overlay gets close to the tail of the overlay buffer.

Two overlay-manager routines, *OvrSetRetry* and *OvrGetRetry,* control the probation/ reprieval mechanism. *OvrSetRetry* sets the size of the area in the overlay buffer to keep on probation and *OvrGetRetry* returns the current setting.

If an overlay falls within the last *OvrGetRetry* bytes before the overlay buffer tail, it's automatically put on probation. Any free space in the overlay buffer is considered part of the probation area.

#### Overlay procedures and functions

The *Overlay* unit-defines a few procedures and functions; find their definitions as well as more details in Chapter I, "Library reference," in the *Programmer's Reference.*

*Chapter* 78, *Using overlays*

18.1
Overlay unit procedures and **Procedure** **Description** functions **or function**

|OvrClearBuf|Clears the|overlay buffer.||||
|---|---|---|---|---|---|
|OvrGetBuf|Returns the|current size|of the overlay|buffer.||
|OvrGetRetry|Returns the value last|current size set with OvrSetRetry.|of the probation|area,|the|
|Ovrlnit|Initializes overlay file.|the overlay|manager and|opens the||
|OvrlnitEMS|Loads the|overlay file|into EMS.|||
|OvrSetBuf|Sets the size|of the overlay|buffer.|||
|OvrSetRetry|Sets the size overlay buffer.|of the "probation|area"|in the||

#### Variables and constants

##### The Overlay unit

Table 18.2

Overlay unit variables **Variable**

*OvrFileMode*

*OvrLoadCount*

*OvrReadBuf*

*OvrResult*

*OvrTrapCount*

Find the values of reference," in the

##### Result codes

|Errors|in the Overlay|unit|are reported|through|the OvrResult||
|---|---|---|---|---|---|---|
|variable.|Look|"ovrXXXX|constants"|in Chapter|1, "Library||
|reference,"|in the|Programmer's|Reference|to find|OvrResult|values.|

up

##### defines five variables:

**Description**

Determines the access code to pass to DOS when the overlay file is opened. The variable incremented each time an overlay is loaded. The procedure variable that lets you intercept overlay load operations. The variable that holds the result code when an *Overlay* procedure executes. The variable incremented each time an overlaid routine is intercepted by the overlay manager.

these variables in Chapter 1, "Library *Programmer's Reference.*

*Language Guide*

overlaid programs

This section provides some important information on designing programs with overlays. Look it over carefully, because a number of the issues discussed are vital to well-behaved overlaid applications.

##### Overlay code

generation Turbo Pascal allows a unit to be overlaid only if it was compiled with {$O+}. In this state, the code generator takes special precau- tions when passing string and set constant parameters from one. overlaid procedure or function to another. For example, if *UnitA* contains a procedure with the following header:

procedure WriteStr(S: string);

##### and if UnitB contains the statement

writeStr(IHello world ... ');

then Turbo Pascal places the string constant 'Hello world ... ' in *UnitB's* code segment, and passes a pointer to it to the *WriteStr* procedure. If both units are overlaid, this doesn't work because, at the call to *WriteStr, UnitB's* code segment can be overwritten by *UnitA's* and the string pointer becomes invalid. The {$O+} dir- ective is used to avoid such problems; whenever Turbo Pascal detects a call from one unit compiled with {$O+} to another unit compiled with {$O+}, the compiler copies all code-segment-based constants into stack temporaries before passing pointers to them.

The use of {$O+} in a unit doesn't force you to overlay that unit. It just instructs Turbo Pascal to ensure that the unit can be overlaid, if so desired. If you develop units that you plan to use in overlaid as well as nonoverlaid applications, compiling them with {$O+} ensures that you can do both with just one version of the unit.

##### The for call

requirement At any call to an overlaid procedure or function in another module, you *must* guarantee that all currently active procedures or functions use the far call model.

This is best illustrated by example: Assume that *Ovr A* is a procedure in an overlaid unit, and that *MainB* and *Maine* are procedures in the main program. If the main program calls

*Chapter* 78, *Using overlays*

*Maine,* which calls *MainB,* which then calls *OvrA,* then at the call to *OvrA, MainB* and *Maine* are active (they have not yet returned) and they are required to use the far call model. Being declared in the main program, *MainB* and *Maine* would normally use the near call model. In this case, a **{$F+}** compiler directive must be used to force the far call model into effect.

The easiest way to satisfy the far call requirement is to place a **{$F+}** directive at the beginning of the main program and each unit. Alternatively, you can change the default **$F** setting to **{$F+}** using a **/$F+** command-line directive or the Force Far Calls check box in the Options I Compiler dialog box. Compared to the cost of mixing near and far calls, using far calls exclusively costs little- one extra word of stack space per active procedure and one extra byte per call.

**the**

**overlay manager** Here we'll take a look at some examples of how to initialize the overlay manager. Place the initialization code before the first call to an overlaid routine. Typically you would do this at the beginning of the program's statement part.

The following code shows just how little you need to initialize the overlay manager:

begin Ovrlnit('EDITOR.OVR'); end;

No error checks are made. If there isn't enough memory for the overlay buffer or if the overlay file was not found, run-time error 208 ("Overlay manager not installed") occurs when you attempt to call an overlaid routine.

Here's another simple example that expands on the previous one:

begin Ovrlnit('EDITOR.OVR'); OvrlnitEMS; end;

In this case, provided there is enough memory for the overlay buffer and that the overlay file can be located, the overlay manager checks to see if EMS memory is available. If it is, it loads the overlay file into EMS.

*Language Guide*

The initial overlay buffer size is as small as possible, or in other words, just big enough to contain the largest overlay. This might be adequate for some applications, but imagine a situation where a particular function of a program is implemented through two or more units, each of which is overlaid. If the total size of those units is larger than the largest overlay, a substantial amount of swapping occurs if the units make frequent calls to each other.

The solution is to increase the size of the overlay buffer so that enough memory is available at any given time to contain all overlays that make frequent calls to each other. The following code demonstrates the use of *OvrSetBuf* to increase the overlay buffer size:

canst OvrMaxSize = 80000; begin Ovrlnit('EDITOR.OVR'); OvrlnitEMS; OvrSetBuf(OvrMaxSize); end;

There is no general formula for determining the ideal overlay buffer size. Only an intimate knowledge of the application and a bit of experimenting results in a suitable value.

Using *OvrlnitEMS* to place the overlay file in EMS doesn't eliminate the need for an overlay buffer. Overlays must still be copied from EMS into "normal" memory in the overlay buffer before they can be executed, but because such in-memory transfers are significantly faster than disk reads, there is less need to increase the size of the overlay buffer.

Remember, *OvrSetBuf* expands the overlay buffer by shrinking the heap. Therefore, the heap must be empty or *OvrSetBufhas* no effect. If you are using the *Graph* unit, make sure you call *OvrSetBuf before* you call *InitGraph,* which allocates memory on the heap.

Here's a rather elaborate example of overlay-manager initiali- zation with full error-checking:

canst OvrMaxSize = 80000; var OvrNarne: string[79]; Size: Longint;

##### 78, Using overlays

begin OvrName := 'EDITOR.OVR'; repeat OvrInit(OvrName); if OvrResult = OvrNotFound then

begin Writeln('Overlay file not found: " OvrName,, .'); Write('Enter correct overlay file name: '); Readln(OvrName); end; until OvrResult <> OvrNotFound; if OvrResult <> OvrOk then begin Writeln('Overlay-manager error.'); Halt (1); end; OvrInitEMS; if OvrResult <> OvrOk then begin case OvrResult of ovrIOError: Write('Overlay file I/O error'); ovrNoEMSDriver: Write('EMS driver not installed'); ovrNoEMSMemory: Write('Not enough EMS memory'); end; Write('. Press Enter ... '); Readln; end; OvrSetBuf(OvrMaxSize); end;

First, if the default overlay file name isn't correct, the user is repeatedly prompted for a correct file name.

Next, a check is made for other errors that might have occurred during initialization. If an error is detected, the program halts because errors in *Ovrlnit* are fatal. (If they are ignored, a run-time error occurs upon the first call to an overlaid routine.)

Assuming successful initialization, a call to *OvrlnitEMS* is made to load the overlay file into EMS if possible. In case of error, a diagnostic message is displayed, but the program isn't halted. Instead, it continues to read overlays from disk.

Finally, *OvrSetBuf* is called to set the overlay buffer size to a suitable value, determined through analysis and experimentation with the particular application. Errors from *OvrSetBuf* are ignored, although *OvrResult* might return an error code of-3 *(OvrNoMemory).* If there isn't enough memory, the overlay

*Language Guide*

manager continues to use the minimum buffer that was allocated when the program started.

**sections** Like static units, overlaid units can have an initialization section. Although overlaid initialization code is no different from normal overlaid code, the overlay manager must be initialized first so it can load and execute overlaid units.

Referring to the earlier *Editor* program, assume that the *EdInOut* and *EdMain* units have initialization code. This requires that *OvrInit* is called before *EdInOut's* initialization code. The only way to do that is to create an additional nonoverlaid unit that goes before *EdInOut* and calls *OvrInit* in its initialization section:

unit Edlnit; interface implementation uses Overlay; const OvrMaxSize = 80000; begin Ovrlnit('EDITOR.OVR'); OvrlnitEMS; OvrSetBuf(OvrMaxSize); end.

The *EdInit* unit must be listed in the program's **uses** clause before any of the overlaid units:

program Editor;

{$F+}

uses Overlay, Crt, Dos, Edlnit, EdlnOut, EdFormat, EdPrint, EdFind, EdMain;

{SO EdlnOut} {SO EdFormat} {SO EdPrint} {SO EdFind} {SO EdMain}

In general, although initialization code in overlaid units is indeed possible, you should avoid it for a number of reasons.

First, the initialization code, even though it's executed only once, is a part of the overlay, and occupies overlay-buffer space when- ever the overlay is loaded. Second, if a number of overlaid units

*Chapter* 18, *Using overlays*

have initialization code, each of them has to be read into memory when the program starts.

A much better approach is to gather all the initialization code into an overlaid initialization unit, which is called once at the begin-. ning of the program, and then never referenced again.

##### What not to

overlay Certain units can't be overlaid. In particular, don't try to overlay the following:

- Units compiled in the {$O-} state. The compiler reports an error if you attempt to overlay a unit that wasn't compiled with {$O+}. Such nonoverlay units include *System, Overlay, Crt,* *Graph, Turbo3,* and *Graph3.*
- Units that contain interrupt handlers. Due to the non-reentrant nature of the DOS operating system, units that implement **interrupt** procedures should not be overlaid. An example of such a unit is the *Crt* standard unit, which implements a *Ctrl+Break* interrupt handler.
- BGI drivers or fonts registered with calls to *RegisterBGldriver* or *RegisterBGIfont.* Calling overlaid routines via procedure pointers is fully sup- ported by Turbo Pascal's overlay manager. Examples of the use of procedure pointers include exit procedures and text-file device drivers. The overlay manager also supports passing overlaid procedures and functions as procedural parameters and assigning overlaid procedures and functions to procedural type variables.
Debugging

overlays Most debuggers have very limited overlay debugging capabilities, if any at all. This isn't so with Turbo Pascal and Turbo Debugger. The integrated debugger fully supports single-stepping and breakpoints in overlays in a manner completely transparent to you. By using overlays, you can easily engineer and debug huge applications-all from inside the IDE or by using Turbo Debugger.

*Language Guide*

**routines**

**in overlays** Like normal Pascal procedures and functions, **external** assembly language routines must observe certain programming rules to work correctly with the overlay manager.

If an assembly language routine makes calls to *any* overlaid procedures or functions, the assembly language routine must use the far model, and it must set up a stack frame using the BP register. For example, assuming that *OtherProc* is an overlaid procedure in another unit, and that the assembly language routine *ExternProc* calls it, then *ExternProc* must use the FAR

|model|and set|up a stack|For example,|||
|---|---|---|---|---|---|
|ExternProc||PROC||||
||PUSH|BP|jSave BP|||
||MOV|BP,SP|jSet up|stack frame||
||SUB|SP,LocalSize|jAllocate|local variables||
||CALL|OtherProc|jCall another|overlaid|unit|
||MOV|SP,BP|jDispose|of local|variables|
||POP|BP|jRestore|BP||
||RET|ParamSize|jReturn|||
|ExternProc||ENDP||||

frame.

FAR

|LocalSize|is the size|of the local|variables|ParamSize|is the|size|
|---|---|---|---|---|---|---|
|of the parameters.||LocalSize|is zero, you|can omit the|two lines||
|to allocate|and dispose|of local|variables.||||
|These|requirements|are the|same ExternProc|makes|indirect||
|references|to overlaid|procedures|or functions.|For example,|||
|OtherProc|makes|calls to overlaid|procedures|or functions,|||
|isn't itself still has|overlaid, to set|ExternProc a stack frame.|must still|use the FAR|model|and|
|When|an assembly|language|routine doesn't|make any|direct|or|
|indirect|references|to overlaid|procedures|or functions,|there|are|
|no special|requirements;|the|assembly language|routine|is free|to|
|use the|near model|and it doesn't|have|set a stack|frame.||
|Overlaid|assembly|language|routines should|not create|variables||
|in the code|segment,|because|any modifications|made|to||
|overlaid|code segment|are lost|when the|overlay is disposed||of.|
|Likewise,|pointers|to objects|based in an|overlaid code|segment||

and If

if if but

up

to up

an

*Chapter* 18, *Using overlays*

#### Installing an overlay-read function

|The OvrReadBuf|procedure|variable|lets you|intercept|overlay||
|---|---|---|---|---|---|---|
|load operations.|For example,||you can implement|error|handling||
|or check|that a removable|disk|is present.|Whenever|the overlay||
|manager|needs to|read overlay,|it calls|the function|whose||
|address|is stored in|OvrReadBuf|the function|returns|zero,|the|
|overlay|manager assumes|that|the operation|was successful;||the|
|function|result is nonzero,|the|compiler generates|run-time|error||
|209. The|OvrSeg parameter|indicates|what|overlay to|load,|as|
|you'll see|later, you|won't need|to access|this information.|||
|To install|your own|overlay-read|function,|you must|first save|the|
|previous|value of OvrReadBufin||a variable|of type OvrReadFunc,|||
|and then|assign your|overlay-read|function|to OvrReadBuf|Within||
|your read|function,|you should|call the saved|read function||to|
|perform|the actual|load operation.|Any validations||you want|to|
|perform,|such as checking|that|a removable|disk is present,|||
|should checking|go before the should go|call the after the call.|saved read|function,|and any|error|
|The code|to install|overlay-read|function|should|go right|after|
|the call of the default|to Ovrlnit; disk|at this point, read function.|OvrReadBuf|contains|the address||
|you also|call OvrlnitEMS,|it|uses your|function|to read||
|overlays|from disk|into EMS|memory, and|no errors|occur,|it|
|stores the|address|of the default|EMS read|function|in||
|Ovr ReadBuf|you|also wish|to override|the EMS read|function,||
|simply|repeat the|installation|process after|the call to|OvrlnitEMS.||
|The default|disk-read|function|returns zero|it succeeds,|or|a|
|DOS error|code|it fails. Likewise,|the default|EMS-read|function||
|returns|0 it succeeds,|or an|EMS error code|(ranging|from|$80|
|through|$FF) it fails.|For details|DOS|error codes,|refer|to the|
|Programmer's|Reference.|For details|EMS|error codes,|refer|to|
|your Expanded|Memory|Specification|documentation.||||
|The following|code|fragment|demonstrates|to write|and||
|install an|overlay-read|function.|The new|overlay-read|function||
|repeatedly|calls the|saved overlay-read|function|until|no errors||

an If if

but

*Don't attempt to call any* *overlaid routines from within* *your overlay-read function-* *such calls crash the system.*

to

an

##### If read

if

If

if if if if on on

how

*Language Guide*

##### DOSError or EMSError pro-

cedures (not shown here) so that they can present the error to the user. Notice how the *OvrSeg* parameter is just passed on to the saved overlay-read function and never directly handled by the new overlay-read function.

uses Overlay; var SaveOvrRead: OvrReadFunc; UsingEMS: Boolean;

function MyOvrRead(OvrSeg: Word): Integer; far; var E: Integer; begin repeat E := SaveOvrRead(OvrSeg); if E <> 0 then if UsingEMS then EMSError(E) else DOSError(E); until E = 0; MyOvrRead := 0; end;

begin OvrInit('MYPROG.OVR'); SaveOvrRead := OvrReadBuf; { Save disk default OvrReadBuf := MyOvrRead; { Install ours UsingEMS := False; OvrInitEMS; if OvrResult = OvrOK then begin SaveOvrRead := OvrReadBuf; Save EMS default OvrReadBuf := MyOvrRead; { Install ours UsingEMS := True; end;

end.

#### Overlays in. EXE files

Turbo Pascal allows you to store your overlays at the end of your application's .EXE file rather than in a separate .OVR file. To attach an .OVR file to the end of an .EXE file, use the DOS COPY command with a command-line switch, for example,

COPY/B MYPROG.EXE + MYPROG.OVR

*Chapter* 78, *Using overlays*

*without*

|You must|make sure|that the|.EXE file was|compiled|||
|---|---|---|---|---|---|---|
|Turbo|debug|information.||the IDE, make|sure|the|
|Standalone|option|isn't checked|in Options|I Debugger.|With|the|
|command-line|version|of the|compiler,|specify|a IV switch.||
|To read|overlays from|the end|of .EXE|file instead|of from|a|
|separate|.OVR file,|simply specify|the .EXE|file name|in the|call to|
|Ovrlnit.|you are|running under|DOS 3.x|greater,|you can|use|
|the|standard|function|to obtain|the name|of the .EXE|file;|

Debugger In

don't

an

##### If or

*ParamStr* for example,

Ovrlnit(PararnStr(O))i

*Language Guide*

Pascal programs use memory. We'll look at the memory map of a Turbo Pascal application, internal data formats, the heap manager, and direct memory access.

#### The Turbo Pascal memory map

Turbo

|Figure 19.1|depicts|the memory|map of a|Pascal|program.|
|---|---|---|---|---|---|
|The Program|Segment|Prefix|(PSP) is a 256-byte|area|built by DOS|
|when the stored in|.EXE file the predeclared|is loaded. variable|segment|address of|PSP is|
|Each module,|which|includes|the main program||each unit,|
|has its own|code segment.|The|main program|occupies|the first|
|code segment;|the|code segments|that follow|are occupied|by|
|the units|(in reverse|order from|how they|are listed in|the uses|
|clause), and|the last|code segment|is occupied|by the|unit.|
|The size|of a single|code segment|can't exceed|64K,|the total|
|size of the|code is|limited only|the available|memory.||

The *PrefixSeg.*

and

it

*System* but by

*Chapter* 79, *Memory issues*

Pascal memory map **Top of DOS memory** HeapEnd--r-----------------------.

**Free memory**

HeapPtr-...•••.......... "f .................

**Heap** (grows upward) HeapOrg--+--------=---=-----=-----------~ OvrHeapEnd **Overlay buffer**
1------------------------....-OvrHeapOrg
**Stack** (grows downward)

1 SSeg:SPtr----------------------------- ------- **Free stack**

#### SSeg:OOOO-I--------------I

**Global variables** ---- - - ------- - ---- - - - --------------I+--- **Typed constants** DSeg:OOOO _i--------------i **System unit code segment**

**First unit code segment** Contents of an .EXE file 1---__---'-_- -image **Last unit code segment**

**Main program code segment**

**Program segment prefix** (PSP)

PrefixSeg __ "----------------------------' **Low memory**

The data segment (addressed through D5) contains all typed constants followed by all global variables. The D5 register is never changed during program execution. The size of the data segment can't exceed 64K.

On entry to the program, the stack segment register (55) and the stack pointer (5P) are loaded so that 55:5P points to the first byte past the stack segment. The register is never changed during program execution, but 5P can move downward until it reaches

*Language Guide*

*OvrSetBuf* routine in the *Overlay* unit; in that case, the size of the heap is decreased accordingly, by moving *HeapOrg* upwards.

The heap stores *dynamic variables,* that is, variables allocated through calls to the *New* and *GetMem* standard procedures. It occupies all or some of the free memory left when a program is executed. The actual size of the heap depends on the minimum and maximum heap values, which can be set with the **$M** com- piler directive. Its size is guaranteed to be at least the minimum heap size and never more than the maximum heap size. If the minimum amount of memory isn't available, the program doesn't execute. The default heap minimum is 0 bytes, and the default heap maximum is 640K; this means that by default the heap occupies all remaining memory.

As you might expect, the heap manager (which is part of Turbo Pascal's run-time library) manages the heap. It's described in detail in the following section.

#### The heap manager

The heap is a stack-like structure that grows from low memory in the heap segment. The bottom of the heap is stored m the variable *HeapOrg,* and the top of the heap, corresponding to the bottom of free memory, is stored in the variable *HeapPtr.* Each time a dynamic variable is allocated on the heap (via *New* or *GetMem),* the heap manager moves *HeapPtr* upward by the size of the variable, in effect stacking the dynamic variables on top of each other.

*HeapPtr* is always normalized after each operation, forcing the offset part into the range $0000 to $OOOF. The maximum size of a single variable that can be allocated on the heap is 65,519 bytes (corresponding to $10000 minus $OOOF), because every variable must be completely contained in a single segment.

*Chapter* 79, *Memory issues*

methods

|The dynamic|variables|stored on|the heap|are disposed|of in one|
|---|---|---|---|---|---|
|of two ways:|(1) through|Dispose|or FreeMem|or (2) through|Mark|
|and Release.|The simplest|scheme|is that of|Mark and|Release; for|
|example,|the following|statements|are executed:|||

if

New(Ptrl)i *New(Ptr2)i* Mark (P) *i* *New(Ptr3)i* *New(Ptr4)i* New(Ptr5) *i*

the layout of the heap will then look like this figure:

Figure 19.2 HeapEnd High

Disposal method using Mark memory and Release HeapPtr Contents of Ptr5" Ptr5 Contents of Ptr4" Ptr4 Contents of Ptr3" Ptr3 Contents of Ptr2" Ptr2 Contents of Ptr1" Low memory Ptr1

*Executing Release(HeapOrg)*The *Mark(P)* statement marks the state of the heap just before *Ptr3* *completely disposes of the* is allocated (by storing the current *HeapPtr* in *P).* If the statement *entire heap because* *HeapOrg points to theRelease(P)* is executed, the heap layout becomes like that of *bottom of the heap.* Figure 19.3, effectively disposing of all pointers allocated since the call to *Mark.*

*Language Guide*

layout with Release(P) HeapEnd-+r--------------, High executed memory

HeapPtr~-------------l Contents of Ptr2"

||Contents|of Ptr2"||
|---|---|---|---|
||Contents|of Ptr1"|Low|
|Ptr1|||memory|

#### Ptr2-.--------------i ----------------'

For applications that dispose of pointers in exactly the reverse order of allocation, the *Mark* and *Release* procedures are very effi- cient. Yet most programs tend to allocate and dispose of pointers in a more random manner, requiring the more sophisticated management technique implemented by *Dispose* and *FreeMem.* These procedures allow an application to dispose of any pointer at any time.

When a dynamic variable that isn't the topmost variable on the heap is disposed of through *Dispose* or *FreeMem,* the heap be- comes fragmented. Assuming that the same statement sequence has been executed, then after executing *Dispose(Ptr3),* a "hole" is created in the middle of the heap (see Figure 19.4).

*Chapter* 79, *Memory issues*

"hole"

||Contents|of Ptr2"||
|---|---|---|---|
|Ptr2||||
||Contents|of Ptr1"|Low|
|Ptr1|||memory|

|in the|HeapEnd|||High|
|---|---|---|---|---|
|heap|HeapPtr|Contents|of Ptr5"|memory|
||Ptr5|Contents|of Ptr4"||
||Ptr4||||

If *New(Ptr3)* had been executed now, it would again occupy the same memory area. On the other hand, executing *Dispose(Ptr4)* enlarges the free block, because *Ptr3* and *Ptr4* were neighboring blocks (see Figure 19.5).

Figure 19.5

Enlarging the free block HeapEnd--.---------------,High

|the free block|HeapEnd|||High|
|---|---|---|---|---|
||Ptr5|Contents --t----~-------____i|of Ptr5"|memory|

#### HeapPtr--t----------------i

||Contents|of Ptr2"||
|---|---|---|---|
|Ptr2||||
||Contents|of Ptr1"|Low|
|Ptr1|||memory|

-+/------------____i ----------------'

an

|Finally,|executing|Dispose(PtrS)||first creates|even bigger|free|
|---|---|---|---|---|---|---|
|block,|and then|lowers|HeapPtr.|This, in effect,|releases|the free|
|block,|because|the last|valid pointer|is now|Ptr2 (see Figure|19.6).|

*Language Guide*

~----------------, High memory

#### HeapPtr-t----------------i -t----------------i

||Contents|of Ptr2"|
|---|---|---|
|Ptr2 Ptr1|Contents|of Ptr1"|

Low -""----------------'memory

|The heap|is now in|the same|state as it|would be|after executing||
|---|---|---|---|---|---|---|
|Release(P),|as shown|in Figure|19.3. The|free blocks|created|and|
|destroyed|in the process|were|tracked|for possible|reuse,|however.|

##### The free list

The addresses and sizes of the free blocks generated by *Dispose* and *FreeMem* operations are kept on *afree list.* Whenever a dynamic variable is allocated, the free list is checked before the heap is expanded. If a free block of adequate size exists (it's greater than or equal to the size of the requested block size), it's used.

The *Release* procedure always clears the free list, therefore causing the heap manager to "forget" about any free blocks that might exist below the heap pointer. If you mix calls to *Mark* and *Release* with calls to *Dispose* and *FreeMem,* you must ensure that no such free blocks exist.

The *FreeList* variable in the *System* unit points to the first free block in the heap. This block contains a pointer to the next free block, which contains a pointer to the following free block, and so on. The last free block contains a pointer to the top of the heap (that is, to the location given by *HeapPtr).* If there are no free blocks on the free list, *FreeList* will be equal to *HeapPtr.*

The format of the first eight bytes of a free block are given by the *TFreeRec* type as follows:

*Chapter* 79, *Memory issues*

##### Size field encodes

the size of the free block. The value in *Size* isn't a normal 32-bit value; rather, it's a "normalized" pointer value with a count of free paragraphs (16-byte blocks) in the high word, and a count of free bytes (between 0 and 15) in the low word. The following *BlockSize* function converts a *Size* field value to a normal *Longint* value:

function BlockSize(Size: Pointer): Longint; type

|PtrRec|record La,|Hi: Word|end;||
|---|---|---|---|---|
|begin|||||
|BlockSize end;|:= Longint(PtrRec(Size)||.Hi)|16 + PtrRec(Size)|

PtrRec = record La, Hi: Word end;

* .Lo;
To guarantee that there will always be room for a *TFreeRec* at the beginning of a free block, the heap manager rounds the size of *every* block allocated by *New* or *GetMem* upwards to an 8-byte boundary. Eight bytes are allocated for blocks of size 1 .. 8, 16 bytes are allocated for blocks of size 9 .. 16, and so on. This might seem an excessive waste of memory at first, and it would be if every block was just 1 byte in size. Blocks are usually larger, however, and so the relative size of the unused space is less.

The 8-byte granularity factor ensures that a number of random allocations and deallocations of blocks of varying small sizes, such as would be typical for variable-length line records in a text- processing program, don't heavily fragment the heap. For example, say a 50-byte block is allocated and disposed of, thereby becoming an entry on the free list. The block would have been rounded to 56 bytes (7*8), and a later request to allocate anywhere from 49 to 56 bytes would completely reuse the block, instead of leaving 1 to 7 bytes of free (but most likely unusable) space, which would fragment the heap.

*Language Guide*

**variable** The *HeapError* variable allows you to install a heap-error function, which is called whenever the heap manager can't complete an allocation request. *HeapError* is a pointer that points to a function with the following header:

function HeapFunc(Size: Word): Integer; far;

Note that the **far** directive forces the heap-error function to use the FAR call model.

The heap-error function is installed by assigning its address to the *HeapError* variable:

HeapError := @HeapFunc;

The heap-error function is called whenever a call to *New* or *GetMem* can't complete the request. The *Size* parameter contains the size of the block that couldn't be allocated, and the heap-error function should attempt to free a block of at least that size.

Depending on its success, the heap-error function should return 0, I, or 2. A return of 0 indicates failure, causing a run-time error to occur immediately. A return of 1 also indicates failure, but instead of a run-time error, it causes *New* or *GetMem* to return a **nil** pointer. Finally, a return of 2 indicates success and causes a retry (which could also cause another call to the heap-error function).

The standard heap-error function always returns 0 and causes a run-time error whenever a call to *New* or *GetMem* can't be completed. For many applications, however, the simple heap- error function that follows is more appropriate:

function HeapFunc(Size: Word): Integer; far; begin HeapFunc := 1; end;

When installed, this function causes *New* or *GetMem* to return **nil** when they can't complete the request, instead of aborting the program.

A call to the heap-error function with a *Size* parameter of 0 means that the heap manager has just expanded the heap by moving *HeapPtr* upwards. This occurs whenever there are no free blocks on the free list, or when all free blocks are too small for the allocation request. Such a call doesn't indicate an error condition,

*Chapter* 79, *Memory issues*

*HeapPtr* has shrunk, and the heap manager ignores the return value.

#### Internal data formats

The next several pages discuss the internal data formats of Turbo Pascal.

##### Integer types

|The|format|selected to|represent|an|integer-type|variable|depends|
|---|---|---|---|---|---|---|---|
|on|its minimum|and|maximum|bounds:||||
|•|If both variable|bounds is stored|are within as a signed|the range byte.|-128|. .127 (Shortint),|the|
|•|If both stored|bounds as an unsigned|are within byte.|the range|0 .. 255|(Byte), the|variable is|
|•|If both variable|bounds is stored|are within as a signed|the range word.|-32768|. .32767 (Integer),|the|
|•|If both is stored|bounds as an unsigned|are within word.|the range|0 .. 65535|(Word),|the variable|
|•|Otherwise, (Longint).|the|variable is|stored|as a signed|double|word|
|A byte.|Char,|or a subrange|of a Char|type,|is stored|as an unsigned||

##### Char types

##### Boolean types

A *Boolean* type is stored as a *Byte,* a *ByteBool* type is stored as a *Byte,* a *WordBool* type is stored as a *Word,* and a *LongBool* type is stored as a *Longint.*

A *Boolean* type can assume the values 0 *(False)* and 1 *(True).* *ByteBool, WordBool,* and *LongBool* types can assume the value of 0 *(False)* or nonzero *(True).*

*Language Guide*

An enumerated type is stored as an unsigned byte if the enumeration has 256 or fewer values; otherwise, it's stored as an unsigned word.

Floating-point

types The floating-point types *(Real, Single, Double, Extended,* and *Camp)* store the binary representations of a sign (+ or-), an *exponent,* and a *significand.* A represented number has the value

+/-significand x 2exponent

where the significand has a single bit to the left of the binary decimal point (that is, 0 <= significand < 2).

In the figures that follow, *msb* means most significant bit, and *lsb* means least significant bit. The leftmost items are stored at the highest addresses. For example, for a real-type value, *e* is stored in the first *byte,fin* the following five bytes, and s in the most significant bit of the last byte.

The Real type A 6-byte (48-bit) *Real* number is divided into three fields: width in bits 1 39 8

e

msb Isbmsb Isb

##### The by the following:

|value v of the|number|is determined|
|---|---|---|
|0 < e <= 255,|then v|= (-1)8|
|e 0, then|v||

##### if * 2(e-129) * (lof).

##### if = = o.

The *Real* type can't store denormals, NaNs, or infinities. Denormals become zero when stored in a *Real,* and NaNs and infinities produce an overflow error if an attempt is made to store them in a *Real.*

*Chapter* 79, *Memory issues*

**The Single type A 4-byte (32-bit) *Single* number is divided into three fields:** **width in bits** 1 8 **23**

|msb Isbmsb 19b The value v of the number is determined by if 0 < e < 255, then v = (-1)5 * 2(e-127) if e = 0 and f <> 0, then v = (-1)5 * 2(-126) if e = 0 and f = 0, then v = (-1)5 * O. if e = 255 and f = 0, then v = (-1)5 * Inf. if e = 255 and f <> 0, then v is a NaN. An 8-byte (64-bit) Double number is divided width in bits 1 11 52|the following: * (lof). * (O.f). into three fields:|
|---|---|
|msb Isbmsb The value v of the number is determined by if 0 < e < 2047, then v = (-1)5 * 2(e-1023) if e = 0 and f <> 0, then v = (-1)5 * 2(-1022) if e = 0 and f = 0, then v = (-1)5 * o. if e = 2047 and f = 0, then v = (-1)5 * Inf. if e = 2047 and f <> 0, then v is a NaN. A la-byte (80-bit) Extended number is divided width in bits 1 15 63 e|19b the following: * (lof). * (O.f). into four fields:|

**The Double type**

**The Extended type**

**msb 19b msb 19b**

##### The following:

|value v of|the number|is determined||by the|
|---|---|---|---|---|
|0 <= e <|32767,|then v|= (-1)5|2(e-16383)|
|e 32767|and f 0,|then v|(-1)5|Inf.|
|e 32767|and f <> 0,|then v|a NaN.||

##### if * * (i.f).

##### if = = = *

##### if = is

***Language Guide***

1 63

d

msb Isb

The value *v* of the number is determined by the following:

if s = 1 and d = 0, then v is a NaN

Otherwise, *v* is the two's complement 64-bit value.

##### Pointer types

|A|Pointer|type|is|stored|as|two|words|(a|double|word),|with|the|
|---|---|---|---|---|---|---|---|---|---|---|---|---|
|offset||part in|the|low|word|and|the|segment||part in|the high||
|word.||The pointer||value|nil|is|stored|as|a double-word||zero.||
|A|string|occupies||as|many|bytes|as|its maximum||length|plus|one.|
|The|first|byte|contains||the|current|dynamic||length|of|the string,||
|and|the|following||bytes|contain||the|characters||of the|string.|The|
|length||byte and||the characters|||are|considered||unsigned|values.||
|Maximum (stri|ng|string [255]).||length|is|255|characters||plus|a length|byte||

##### String types

##### Set types

A set is a bit array, where each bit indicates whether an element is in the set or not. The maximum number of elements in a set is 256, so a set never occupies more than 32 bytes. The number of bytes occupied by a particular set is calculated as

ByteSize = (Max div 8)-(Min div 8) + 1

where *Min* and *Max* are the lower and upper bounds of the base type of that set. The byte number of a specific element E is

ByteNumber = (E div 8)-(Min div 8)

##### and the bit number within that byte is

BitNumber = E mod

where E denotes the ordinal value of the element.

*Chapter* 79, *Memory issues*

|An|array|is|stored|as|a|contiguous|sequence|of|variables|of|the|
|---|---|---|---|---|---|---|---|---|---|---|---|
|component|||type|of the||array.|The components||with|the lowest||
|indexes||are|stored|at|the|lowest|memory|addresses.||A multi-||
|dimensional increasing|||array first.|is|stored|with|the rightmost||dimension|||
|The|fields|of|a record||are|stored|as a contiguous||sequence||of|
|variables.||The|first|field||is stored|at the lowest||memory|address.|If|
|the same|record memory||contains address.|variant||parts,|then each|variant|starts|at|the|

##### Object types

The internal data format of an object resembles that of a record. The fields of an object are stored in order of declaration, as a contiguous sequence of variables. Any fields inherited from an ancestor type are stored before the new fields defined in the descendant type.

If an object type defines virtual methods, constructors, or destruc- tors, the compiler allocates an extra field in the object type. This 16-bit field, called the *virtual method table (VMT) field,* is used to store the offset of the object type's VMT in the data segment. The VMT field immediately follows after the ordinary fields in the object type. When an object type inherits virtual methods, con- structors, or destructors, it also inherits a VMT field, so an addi- tional one isn't allocated.

Initialization of the VMT field of an instance is handled by the object type's constructor(s). A program never explicitly initializes or accesses the VMT field.

The following examples illustrate the internal data formats of object types:

*Language Guide*

|type|||
|---|---|---|
|PLocation|ATLocation;||
|TLocation|object||
|X, Y:|Integer;||
|procedure|Init(PX,|PY: Integer);|
|function|GetX: Integer;||
|function|GetY: Integer;||
|end;|||
|PPoint|ATPoint;||
|TPoint|object(TLocation)||
|Color:|Integer;||
|constructor|Init(PX,|PY, PColor:|
|destructor|Done;||
|procedure|Show;||
|procedure|Hide;||
|procedure|MoveTo(PX,|PY: Integer);|
|end;|||
|PCircle|ATCircle;||
|TCircle|object (TPoint)||
|Radius:|Integer;||
|constructor|Init(PX,|PY, PColor,|
|procedure|Show;||
|procedure|Hide;||
|procedure|||
|end.|||

= = I

= =

Integer); Bvirtual; virtual; virtual; virtual;

= =

PRadius: Integer); virtual; virtual; Fill; virtual;

Figure 19.7 shows layouts of instances of *TLocation, TPoint,* and

##### TCircle; each word of storage.

||box corresponds|to one|
|---|---|---|
|and TCircie|Point|Circle|
||Color|Color|
||VMT|VMT Radius|

Location x x TPoint,y y

Virtual method tables Each object type that contains or inherits virtual methods, con- structors, or destructors has a VMT associated with it, which is stored in the initialized part of the program's data segment. There is only one VMT per object type (not one per instance), but two distinct object types never share a VMT, no matter how identical they appear to be. VMTs are built automatically by the compiler, and are never directly manipulated by a program. Likewise, pointers to VMTs are automatically stored in object type instances

*Chapter* 79, *Memory issues*

by the object type's constructor(s) and are never directly manipulated by a program.

The first word of a VMT contains the size of instances of the associated object type; this information is used by constructors and destructors to determine how many bytes to allocate or dispose of, using the extended syntax of the *New* and *Dispose* standard procedures.

The second word of a VMT contains the negative size of instances of the associated object type; this information is used by the virtual method call validation mechanism to detect uninitialized objects (instances for which no constructor call has been made), and to check the consistency of the VMT. When virtual call validation is enabled (using the **{$R+}** compiler directive, which has been expanded to include virtual method checking), the compiler generates a call to a VMT validation routine before each virtual call. The VMT validation routine checks that the first word of the VMT isn't zero, and that the sum of the first and the second word is zero. If either check fails, the compiler generates run-time error 210.

Enabling range checking and virtual method call checking slows down your program and makes it somewhat larger, so use the **{R+}** state only when debugging, and switch to the **{$R-}** state for the final version of the program.

*See page* 225 *for an*The third word of a VMT contains the data segment offset of the *explanation of dynamic* object type's dynamic method table (DMT), or zero if the object *method tables.* type has no dynamic methods.

The fourth word of a VMT is reserved and always contains zero.

Finally, starting at offset 8 in the VMT, is a list of 32-bit method pointers, one per virtual method in the object type, in order of declaration. Each slot contains the address of the corresponding virtual method's entry point.

Figure 19.8 shows the layouts of the VMTs of the *TPoint* and

*TCircle* types; each small box corresponds to one word of storage, and each large box corresponds to two words of storage.

*Language Guide*

VMT VMT

|TPoint|TCircie|
|---|---|
|VMT||
|layouts 8|10|
|-8|-10|
|0|0|
|0|0|
|@TPoint.Done|@TPoint.Done|

TPoint and TCircle's

@TPoint.Show @TCircle.Show

@TPoint.Hide @TCircle.Hide

@TPoint.MoveTo @TPoint.MoveTo

@TCircle.Fili

inherits *Done*

|Notice how|TCircle|the|and MoveTo|methods|from|
|---|---|---|---|---|---|
|TPoint, and|how it overrides|the|Show and Hide|methods.||
|As mentioned|already,|object|type's constructors|contain||
|special code|that stores|the offset|of the object|type's VMT|the|
|instance|being initialized.|For example,|given|an instance|P of|
|type Pointer,|and|instance C|type TCircle,|a call to|P.Init|
|automatically|stores|the offset of|TPoint's VMT|in P's VMT|field,|
|and a call|to C.lnit likewise|stores|the offset|TCircle's|VMT in C's|
|VMT field.|This automatic|initialization|is part|of a constructor's||
|entry code,|so when|control arrives|at the begin|of the construc-||
|tor's statement|part,|the VMT field|Self is already|set up.||
|Therefore, virtual methods.|the need|arises, a constructor|can|make calls|to|
|The VMT|for object|type contains|a four-byte|entry (a|method|
|pointer)|for each virtual|method|declared in|the object type|and|
|any of its|ancestors.|cases where|ancestral|type(s) define|a large|
|number|of virtual methods,|the|process of creating|derived|types|
|can use|quite a lot|of memory,|especially|many derived|types|

an in

an of

of

if

Dynamic method an tables In

up if

*Chapter* 79, *Memory issues*

VMT of each derived type contains method pointers for all inherited virtual methods, even if they haven't changed.

Dynamic methods provide an alternative in such situations. Instead of encoding a pointer for *all* late-bound methods in an object type, a dynamic method table (DMT) encodes only the methods that were *overridden* in the object type. When descendant types override only a few of a large number of inherited late- bound methods, the dynamic method table format uses less space than the format used by VMTs.

##### The DMT formats:

|following|two object|types illustrate|
|---|---|---|
|type|||
|TBase X: Integer; constructor|object||
|destructor|Done;||
|procedure|P10;|10;|
|procedure|P20;|20;|
|procedure|P30;|30;|
|procedure end; type TDerived Y: Integer; constructor|P40; object(TBase)|40;|
|destructor|Done;||
|procedure|P10;|10;|
|procedure|P30;|30;|
|procedure end;|P50;|50;|

=

Init; virtual; virtual virtual virtual virtual

=

Init; virtual; virtual virtual virtual

|Figures|19.9 and|19.10 shows|the layouts|of the|VMTs and|DMTs|
|---|---|---|---|---|---|---|
|of TBase|and TDerived.|Each|small box|corresponds|to one|word|
|storage,|and each|large box|corresponds|to two|words of|storage.|

of

*Language Guide*

TBase VMT TBase DMT

|4||0||
|---|---|---|---|
|-4||Cached index||
|Offset of TBase DMT||Cached entry offset||
|o||4||
|||10||
|@TBase.Done||20||
|||30||
|||40 @TBase.P10 @TBase.P20 @TBase.P30 @TBase.P40||

layouts

An object type has a DMT only if it introduces or overrides dynamic methods. If an object type inherits dynamic methods, but doesn't override any of them or introduce new ones, it simply inherits the DMT of its ancestor.

As is the case for VMTs, DMTs are stored in the initialized part of the application's data segment.

*Chapter* 19, *Memory issues*

|6||Offset of TBase DMT|
|---|---|---|
|~--------------~ -6||Cached index|
|Offset of TDerived DMT||Cached entry offset|
|o||3|
|||10|
|@TDerived.Done||30|
|||50 @TDerived.P10 @TDerived.P30 @TDerived.P50|
|The first word of a DMT parent DMT, or zero if The second and third words method lookups, as is word of a DMT The fourth immediately followed dynamic method index, ing method pointers. The entry count.|there described by and|contains the data segment is no parent DMT. of a DMT are used on page 239. contains the DMT entry a list of words, each of then followed by a length of each list is given|

layouts

offset of the

##### to cache dynamic

*count.* It's which contain a list of correspond- by the DMT

##### File types

File types are represented as records. Typed files and untyped files occupy 128 bytes, which are laid out in the *Dos* unit as follows:

*Language Guide*

..

|UserData:|array[1|16]|of Byte;|
|---|---|---|---|
|Name: end;|array[O|79] of Char;||

..

##### Text files occupy 256 bytes, which are laid out as follows:

**type** TextBuf = **array[O .**. 127] **of** Char; TextRec = **record** Handle: Word; Mode: Word; BufSize: Word; Private: Word; BufPos: Word; BufEnd: Word; BufPtr: ATextBuf; OpenFunc: Pointer; InOutFunc: Pointer; FlushFunc: Pointer; CloseFunc: Pointer; UserData: array[1 .. 16] **of** Byte; Name: array[O .. 79] **of** Char; Buffer: TextBuf; **end;**

##### Handle contains the file's handle (when the file is open) as returned by DOS.

##### The Mode field can assume one of the following J/ magic" values:

**const** fmClosed = $D7BO; fmlnput = $D7B1; fmOutput = $D7B2; fmlnOut = $D7B3;

##### fmClosed indicates that the file is closed. fmlnput and fmOutput

##### indicate that the file is a text file that has been reset (jmlnput) or

##### rewritten (jmOutput). fmlnOut indicates that the file variable is a

**typed or an untyped file that has been reset or rewritten. Any** **other value indicates that the file variable hasn't been assigned** **(and thereby not initialized).**

The *UserData* field is never accessed by Turbo Pascal, and is free for user-written routines to store data in.

*Name* contains the file name, which is a sequence of characters terminated by a null character (#0).

For typed files and untyped files, *RecSize* contains the record length in bytes, and the *Private* field is unused but reserved.

For text files, *BufPtr* is a pointer to a buffer of *BujSize* bytes, *BufPos* is the index of the next character in the buffer to read or write, and *BufEnd* is a count of valid characters in the buffer. *OpenFunc,* *InOutFunc, FlushFunc,* and *CloseFunc* are pointers to the I/O routines that control the file. The section entitled "Text file device drivers" in Chapter 13 provides information on that subject.

types

A procedural type is stored as a double word, with the offset part of the referenced procedure in the low word and the segment part in the high word.

#### Direct memory access

Turbo Pascal implements three predefined arrays, *Mem, Mem* W, and *MemL,* which are used to directly access memory. Each com- ponent of *Mem* is a byte, each component of *MemW* is a *Word,* and each component of *MemL* is a *Longint.*

The *Mem* arrays use a special syntax for indexes: Two expressions of the integer type *Word,* separated by a colon, are used to specify the segment base and offset of the memory location to access.

|Here are|some examples:||
|---|---|---|
|Mem[$0040:$0049]||:= 7i|
|Data|:= MemW[Seg(V)|:OfS(V)]i|
|MemLong|:= MemL[64:3*4]i||

|The first|statement|stores the|value 7 in|the byte|at $0040:$0049.||
|---|---|---|---|---|---|---|
|The second|statement|moves|the Word|value stored|in the|first 2|
|bytes of|the variable|V into the|variable|Data. The|third statement||
|moves|the Longint|value stored|at $0040:$000C|into|the variable||

*MemLong.*

*Language Guide*

For access to the 80x86 CPU data ports, Turbo Pascal implements two predefined arrays, *Port* and *PortW.* Both are one-dimensional arrays, and each element represents a data port, whose port address corresponds to its index. The index type is the integer type *Word.* Components of the *Port* array are of type *Byte,* and components of the *PortWarray* are of type *Word.*

When a value is assigned to a component of *Port* or *PortW,* the value is output to the selected port. When a component of *Port* or *PortWis* referenced in an expression, its value is input from the selected port.

Use of the *Port* and *Port* W arrays is restricted to assignment and reference in expressions only; that is, components of *Port* and *PortW* can't be used as variable parameters. Also, references to the entire *Port* or *PortW* array (reference without index) aren't allowed.

*Chapter* 79, *Memory issues*

#### 20 Control issues

This chapter describes in detail the various ways that Turbo Pascal implements program control. Included are calling con- ventions and exit procedures.

#### Calling conventions

Parameters are transferred to procedures and functions via the stack. Before calling a procedure or function, the parameters are pushed onto the stack in their order of declaration. Before return- ing, the procedure or function removes all parameters from the stack. '

The skeleton code for a procedure or function call looks like this:

PUSH Paraml PUSH Param2

PUSH PararnX CALL ProcOrFunc

Parameters are passed either by *reference* orby *value.* When a parameter is passed by reference, a pointer that points to the actual storage location is pushed onto the stack. When a param- eter is passed by value, the actual value is pushed onto the stack.

*Chapter 20, Control issues*

PUSH and POP instructions, so byte-sized parameters are always transferred onto the stack as words. The low-order byte of the word contains the value, and the high-order byte is unused (and undefined).

An integer type or parameter is passed as a byte, a word, or a double word, using the same format as an integer-type variable. (For double words, the high-order word is pushed before the low-order word so that the low-order word ends up at the lowest address.)

A *Char* parameter is passed as an unsigned byte.

A *Boolean* parameter is passed as a byte with the value 0 or 1.

An enumerated-type parameter is passed as an unsigned byte if the enumeration has 256 or fewer values; otherwise, it's passed as an unsigned word.

A floating-point type parameter *(Real, Single, Double, Extended,* and *Comp)* is passed as 4,6,8, or 10 bytes on the stack. This is an exception to the rule that only 1-, 2-, and 4-byte values are passed directly on the stack.

A pointer-type parameter is passed as two words (a double word). The segment part is pushed before the offset part so that the offset part ends up at the lowest address.

A string-type parameter is passed as a pointer to the value.

For a set type parameter, if the bounds of the element type of the set are both within the range to 7, the set is passed as a byte. If

*Language Guide*

the bounds are both within the range 0 to 15, the set is passed as a word. Otherwise, the set is passed as a pointer to an unpacked set that occupies 32 bytes.

Arrays and records with I, 2, or 4 bytes are passed directly onto the stack. Other arrays and records are passed as pointers to the value.

**parameters**

Open string parameters are passed by first pushing a pointer to the string and then pushing a word containing the size attribute (maximum length) of the string.

Open array parameters are passed by first pushing a pointer to the array and then pushing a word containing the number of elements in the array less one.

When using the built-in assembler, the value that the *High* standard function returns for an open parameter can be accessed by loading the word just below the open parameter. In this example, the *FillString* procedure, which fills a string to its maximum length with a given character, demonstrates this.

procedure FillString(var Str: OpenString; Chr: Char); assembler; asm LES DI,Str { ES:DI = @Str }

|LES|DI,Str|{ES:DI|@Str}||
|---|---|---|---|---|
|MOV|CX,Str.Word[-2)|(CX|High(Str)||
|MOV CLD|AL,CL||||
|STOSB||(Set Str[O)|}||
|MOV|AL,Chr||||
|REP end;|STOSB|(Set|High)||

=

##### Str[l ..

##### Function results

Ordinal-type function results are returned in the CPU registers: Bytes are returned in AL, words are returned in AX, and double words are returned in DX:AX (high-order word in DX, low-order word in AX).

Real-type function results (type *Real)* are returned in the DX:BX:AX registers (high-order word in DX, middle word in BX, low-order word in AX).

*Chapter 20, Control issues*

|80x87-type|function|results (type|Single,|Double,|Extended,|and|
|---|---|---|---|---|---|---|
|Comp) are (ST(O)).|returned|in the 80x87|coprocessor's|top-of-stack||register|
|Pointer-type in OX, offset|function part in|results AX).|are returned|in OX:AX|(segment|part|
|For a string-type|function|result,|the caller|pushes|a pointer|to a|
|temporary|storage location|before|pushing|any parameters,||and|
|the function|returns|a string value|in that|temporary|location.|The|
|function|must not remove|the|pointer.||||

calls The 80x86 family of CPUs support two kinds of call and return instructions: near and far. The near instructions transfer control to another location within the same code segment, and the far instructions allow a change of code segment.

A NEAR CALL instruction pushes a 16-bit return address (offset only) onto the stack, and a FAR CALL instruction pushes a 32-bit return address (both segment and offset). The corresponding RET instructions pop only an offset or both an offset and a segment.

Turbo Pascal automatically selects the correct call model based on the procedure's declaration. Procedures declared in the interface section of a unit are far-they can be called from other units. Procedures declared in a program orin the **implementation** section of a unit are near-they can only be called from within that program or unit.

For some specific purposes, a procedure can be required to be far. For example, if a procedure or function is to be assigned to a procedural variable, it must be far. The **$F** compiler directive is used to override the compiler's automatic call model selection. Procedures and functions compiled in the {$F+} state are always far; in the {$F-} state, Turbo Pascal automatically selects the correct model. The default state is {$F-}.

Nested

procedures and A procedure or function is said to be nested when it's declared

functions within another procedure or function. By default, nested proce- dures and functions always use the near call model, because they are visible only within a specific procedure or function in the same code segment. In an overlaid application, however, a {$F+}

*Language Guide*

directive is generally used to force all procedures and functions to be far, including those that are nested.

When calling a nested procedure or function, the compiler generates a PUSH BP instruction just before the CALL, in effect passing the caller's BP as an additional parameter. Once the called procedure has set up its own BP, the caller's BP is accessible as a word stored at [BP + 4], or at [BP + 6] if the procedure is far. Using this link at [BP + 4] or [BP + 6], the called procedure can access the local variables in the caller's stack frame. If the caller itself is also a nested procedure, it also has a link at [BP + 4] or [BP + 6], and so on. The following example demonstrates how to access local variables from an **inline** statement in a nested procedure:

procedure A; near; var IntA: Integer;

procedure B; far; var IntB: Integer;

procedure C; near; var IntC: Integer; begin asm MOV AX,l MOV IntC,AX { IntC := 1 } MOV BX, [BPt4] { B's stack frame} MOV SS: [BXtOFFSET IntB],AX { IntB := 1 } MOV BX, [BPt4] { B's stack frame} MOV BX, S S: [BX t 6] { A's stack frame} MOV SS: [BXtOFFSET IntA],AX { IntA := 1 } end; end;

begin C end;

begin Bend;

calling

|Methods|use the same|calling|conventions|as ordinary|procedures||
|---|---|---|---|---|---|---|
|and functions,|except|that every|method|has an additional|||
|implicit|parameter,|Self, that|corresponds|to a var|parameter|of the|
|same type|as the method's|object|type.|The Self parameter||is|
|always|as the|last parameter,|and|always|takes the|form of|
|a 32-bit|pointer to the|instance|through|which the|method|is|

conventions

passed

*Chapter* 20, *Control issues*

##### PP of type PPoint as defined

|on page|223, the|call PP/\.MoveTo(10,||20) is coded|as follows:|
|---|---|---|---|---|---|
|MOV|AX,10||iLoad 10 into|AX||
|PUSH|AX||iPass as PX|parameter||
|MOV|AX,20||iLoad 20 into|AX||
|PUSH|AX||iPass as PY|parameter||
|LES|DI,PP||iLoad PP into|ES:DI||
|PUSH|ES||iPass as Self|parameter||
|PUSH|DI|||||
|MOV|DI,ES:|[DI+6]|iPick up VMT||from VMT|
|CALL|DWORD|PTR [DI+20]|iCall VMT|entry for|MoveTo|

offset field

Upon returning, a method must remove the *Self* parameter from the stack, just as it must remove any normal parameters.

Methods always use the far call model, regardless of the setting of the **{$F}** compiler directive.

**calls**

|To call a virtual|method,|the compiler|generates|code|that picks|
|---|---|---|---|---|---|
|the VMT|address|the VMT|field in|the object,|and then|
|calls via the|slot associated|with|the method.|For example,|given|
|variable PP|of type Point|(see page|223), the|call PP/\.Show||

up from a

|generates|the following|code:||||
|---|---|---|---|---|---|
|LES|DI,PP||iLoad PP into|ES:DI||
|PUSH|ES||iPass as Self|parameter||
|PUSH|DI|||||
|MOV|DI,ES:|[DI+6]|iPick up VMT|from|VMT|
|CALL|DWORD|PTR [DI+12]|iCall VMT entry|for Show||

offset field

The type compatibility rules of object types allow PP to point at a *Point* or a *TCircle,* or at any other descendant of *TPoint.* And if you examine the VMTs shown on page 225, you'll see that for a *TPoint,* the entry at offset 12 in the VMT points to *TPoint.Show;* whereas for a *TCircle,* it points to *TCircle.Show.* Therefore, depending upon the *actual* run-time type of *PP,* the CALL instruction calls *TPoint.Show* or *TCircle.Show,* or the *Show* method of any other de- scendant of *TPoint.*

If *Show* had been a static method, the compiler would have generated this for the call to *PP/\.Show:*

*Language Guide*

|LES|Dl,PP|iLoad PP|into ES:Dl|
|---|---|---|---|
|PUSH|ES|iPass as|Self parameter|
|PUSH|Ol|||
|CALL|TPoint.Show|iDirectly|TPoint.Show|

call

Here, no matter what PP points to, the code always calls the *TPoint.Show* method.

|Dispatching|a dynamic|method|call is somewhat|more|compli-||
|---|---|---|---|---|---|---|
|cated and|time consuming|than|dispatching|a virtual|method|call.|
|Instead|of using a CALL|instruction|to call|through a|method||
|pointer at|a static offset|in the VMT,|the object|type's|DMT and||
|parent DMTs|must|scanned to|find the topmost|occurrence||of a|
|particular|dynamic|index,|and then|a call must|be made||
|through|the corresponding|method|pointer.|This process|involves||
|far more|instructions|than can be|coded in-line,|so the|Turbo||
|Pascal run-time|library|(RTL) contains|a dispatch-support||routine||
|that is used|when making|dynamic|method|calls.|||
|the|Show method|of the preceding|type|TPoint been|declared||
|as a dynamic|method|(with a dynamic|method|index|of 200),|the|
|call PPA.Show,|where|PP is of type|Point, would|generate|the||

**calls**

be method

Had

|following|code:||||
|---|---|---|---|---|
|LES|Ol,PP|iLoad PP into|ES:Dl||
|PUSH|ES|iPass as Self|parameter||
|PUSH|Ol||||
|MOV|Ol,EX:|iPick up VMT|from|VMT|
|MOV|AX,200|iLoad dynamic|method index|into AX|
|CALL|Dispatch|iCall RTL routine|to dispatch||

[0l+6] offset field

call

up

|The RTL|dispatcher|first picks|the DMT|offset from|the VMT||
|---|---|---|---|---|---|---|
|pointed to|by the DI|register. Then,|using|cached|index"|field|
|of the DMT,|the dispatcher|checks|the dynamic|method|index|of|
|the method|being called|is the same|as the|last one that|was||
|called.|so, it immediately|transfers|control|to the method,|||
|jumping|indirectly through|the|method pointer|stored|at the||
|offset given|by|cached entry|offset" field.||||
|the dynamic|index|of the method|being called|isn't|the same|as|
|the one stored|in the|cache, the|dispatcher|scans the DMT|and|the|
|parent DMTs|(by following|the|parent links|in the DMTs)|until|it|
|locates|entry with|the given|dynamic method|index.|The index||
|and the offset|of the corresponding||method|pointer is|then stored||
|in the DMT's|cache fields,|and control|is transferred|to|the||

the" if

##### If by

the"

If

an

*Chapter* 20, *Control issues*

210.
In spite of caching and a highly optimized RTL dispatch support routine, the dispatching of a dynamic method call takes sub- stantially longer than a virtual method call. When the actions performed by the dynamic methods themselves take up a lot of time, however, the amount of space saved by using DMTs might outweigh this penalty.

Constructors and destructors use the same calling conventions as other methods, except that an additional word-sized parameter, called the *VMT* parameter, is passed on the stack just before the *Self* parameter.

For constructors, the VMT parameter contains the VMT offset to store in *Selfs* VMT field to initialize *Self.*

When a constructor is called to allocate a dynamic object using the extended syntax of the *New* standard procedure, a **nil** pointer is passed in the *Self* parameter. The constructor allocates a new dynamic object, the address of which is passed back to the caller in DX:AX when the constructor returns. If the constructor can't al- locate the object, a **nil** pointer is returned in DX:AX.

|See "Constructor||error|
|---|---|---|
|recovery"|on page|706.|

Finally, when a constructor is called using a qualified-method identifier (that is, an object type identifier, followed by a period and a method identifier), a value of zero is passed in the VMT parameter. This indicates to the constructor that it should *not* initialize the VMT field of *Self.*

For destructors, a 0 in the VMT parameter indicates a normal call, and a nonzero value indicates that the destructor was called using the extended syntax of the *Dispose* standard procedure. This causes the destructor to deallocate *Self* just before returning (the size of *Selfis* found by looking at the first word of *Self's* VMT).

##### Entry and exit

**code** Each Pascal procedure and function begins and ends with standard entry and exit code.

*Language Guide*

entry

|This is|the standard|code:||
|---|---|---|---|
|PUSH|BP|iSave BP||
|MOV|BP,SP|iSet up|stack frame|
|SUB|SP,LocalSize|iAllocate|locals|

(if any)

|LoealSize|is the size|of the local|variables.|The SUB|instruction|is|
|---|---|---|---|---|---|---|
|present|only if LoealSize|isn't O.|the procedure's||call model|is|
|near, the|parameters|start at BP|+ 4; if it's|far, they|start at|BP + 6.|

If

exit

|This is|the standard|code:|||
|---|---|---|---|---|
|MOV|SP,BP|iDeallocate|locals|any)|
|pOP|BP|iRestore|BP||
|RET|ParamSize|iRemove|parameters|and return|

(if

*ParamSize* is the size of the parameters. The RET instruction is either a near or far return, depending on the routine's call model.

Procedures and functions should preserve the BP, SP, SS, and DS registers. All other registers can be modified.

By installing an exit procedure, you can gain control over a program's termination process. This is useful when you want to make sure specific actions are carried out before a program terminates; a typical example is updating and closing files.

The *ExitProe* pointer variable allows you to install an exit procedure. The exit procedure is always called as a part of a program's termination, whether it's a normal termination, a termination through a call to *Halt,* or a termination due to a run- time error.

An exit procedure takes no parameters and must be compiled with a **far** procedure directive to force it to use the far call model.

When implemented properly, an exit procedure actually becomes part of a chain of exit procedures. This chain makes it possible for units as well as programs to install exit procedures. Some units install an exit procedure as part of their initialization code and then rely on that specific procedure to be called to clean up after the unit. Closing files is such as example. The procedures on the

*20, Control issues*

Pointer;

|procedure|MyExit;|far;|||
|---|---|---|---|---|
|begin|||||
|ExitProc end; begin ExitSave ExitProc end.|:= ExitSave; := ExitProc; := @MyExit;||{Always|old vector|

restore first }

On entry, the program saves the contents of *ExitProc* in *ExitSave,* and then installs the *MyExit* exit procedure. After having been called as part of the termination process, the first thing *MyExit* does is reinstall the previous exit procedure.

The termination routine in the run-time library keeps calling exit procedures until *ExitProc* becomes **nil.** To avoid infinite loops, *ExitProc* is set to **nil** before every call, so the next exit procedure is called only if the current exit procequre assigns an address to *ExitProc.* If an error occurs in an exit procedure, it won't be called again.

An exit procedure can learn the cause of termination by examining the *ExitCode* integer variable and the *Error Addr* pointer variable.

In case of normal termination, *ExitCode* is zero and *Error Addr* is **nil.** In case of termination through a call to *Halt, ExitCode* contains the value passed to *Halt,* and *ErrorAddr* is **nil.** Finally, in case of termination due to a run-time error, ExitCodecontains the error code and *ErrorAddr* contains the address of the statement in error.

*Language Guide*

Once the run-time library has called all exit procedures, it returns to DOS, passing the value stored in *ExitCode* as a return code.

#### Interrupt handling

The Turbo Pascal run-time library and the code generated by the compiler are fully interruptible. Also, most of the run-time library is reentrant, which allows you to write interrupt service routines in Turbo Pascal.

##### Writing interrupt

**procedures** Declare **interrupt** procedures with the **interrupt** directive. Every **interrupt** procedure must specify the following procedure header (or a subset of it, as explained later):

es, ex,

|procedure|IntHandler(Flags,|IP, AX, BX,|DX, SI, DI,|DS, ES,|
|---|---|---|---|---|
|BP: begin end;|Word};||||

interrupt;

|As you can|see, all|the registers|are passed|as pseudoparameters||
|---|---|---|---|---|---|
|so you can|use and|modify them|in your|code. You|can omit some|
|or all of the|parameters,|starting|with Flags|and moving|towards|
|BP. It's an|error to declare|more|parameters|than are|listed in the|
|preceding|example,|or to omit|a specific|parameter|without also|
|omitting|the ones before|it (although|no|error is reported).|For|

example,

|procedure|IntHandler(DI,|ES, BP: Word};||Invalid|header|}|
|---|---|---|---|---|---|---|
|procedure|IntHandler(SI,|DI, DS, ES,|BP: Word};|{Valid|header|}|

*Chapter 20, Control issues*

##### On entry, an interrupt procedure automatically saves all registers

##### (regardless of the procedure header) and initializes the DS register:

PUSH AX PUSH BX PUSH ex PUSH DX PUSH S1 PUSH DI PUSH DS PUSH ES PUSH BP MOV BP,SP SUB SP,LocalSize MOV AX,SEG DATA MOV DS,AX

##### Notice the lack of a STI instruction to enable additional interrupts.

**You should code this yourself (if required) using an inline statement. The exit code restores the registers and executes an**

**interrupt-return instruction:**

MOV SP, BP pOP BP pOP ES pOP DS pOP D1 pOP S1 pOP DX POP ex pOP BX pOP AX 1RET

**An interrupt procedure can modify its parameters. Changing the declared parameters will modify the corresponding regi?ter when**

**the interrupt handler returns. This can be useful when you are** **using an interrupt handler as a user service, much like the DOS** **INT 21H services.**

**Interrupt procedures that handle hardware-generated interrupts should not use any of Turbo Pascal's input and output or dynamic**

##### memory allocation routines,because they aren't reentrant.

##### Likewise, no DOS functions can be used because DOS isn't reentrant.

***Language Guide***

***code***

Turbo Pascal performs several different types of code optimi- zations, ranging from constant folding and short-circuit Boolean expression evaluation, all the way up to smart linking. The following sections describe some of the types of optimizations performed and how you can benefit from them in your programs.

#### Constant folding

If the operand(s) of an operator are constants, Turbo Pascal evaluates the expression at compile time. For example,

*

|X := 3|+ 4 2|||
|---|---|---|---|
|||X. -11,||
|S :=|+ 'Out'|S : InOut|I.|

generates the same code as and

'In'

generates the same code as = *I*

Likewise, if an operand of an *Abs, Chr, Hi, Length, Lo, Odd, Ord,* *Pred, Ptr, Round, Succ, Swap,* or *Trunc* function call is a constant, the function is evaluated at compile time.

If an array index expression is a constant, the address of the ·component is evaluated at compile time. For example, accessing *Data[5,* 5] is just as efficient as accessing a simple variable.

*Chapter* 7, *Optimizing your code*

**evaluation**

Turbo Pascal implements short-circuit Boolean evaluation, which means that evaluation of a Boolean expression stops as soon as the result of the entire expression becomes evident. This guaran- tees minimum execution time and usually ~inimum code size. Short-circuit evaluation also makes possible the evaluation of constructs For example,

|that|would|not otherwise|be legal.|
|---|---|---|---|
|while (I <= Inc (I) i|Length{S))|and (S[I]|<> ' ') do|
|while (P <> p := pA.Nexti|and|(pA.Value|<> 5) do|

nil)

evaluated

|In both cases,|the second|test isn't|if the|first test|is|
|---|---|---|---|---|---|
|The opposite|of short-circuit|evaluation|is complete|evaluation,||
|which is|through|a {$B+}|directive.|In this|state,|
|every operand|of a Boolean|expression|is guaranteed|to be||

*False.*

selected compiler

evaluated.

#### Constant parameters

|Read more|about constant||
|---|---|---|
|parameters|on page|709.|

you

|Whenever|possible,|should|use constant|parameters|instead||
|---|---|---|---|---|---|---|
|of value|parameters.|Constant|parameters|are at least|as efficient||
|as value|parameters|and, in|many cases,|more efficient.|In||
|particular,|constant|parameters|generate|less code|execute||
|faster|than value|parameters|for structured|and string|types.||
|Constant|parameters|are more|efficient|than value|parameters||
|because|the compiler|doesn't|have to generate|copies|the|actual|
|parameters|upon|entry to procedures|or|functions.|Value||
|parameters|have|to be copied|into local|variables|so that||
|modifications|made|to the formal|parameters||modify|the|

and

of

won't

*Language Guide*

cons~ant formal parameters can't be modified, the compiler has no need to generate copies of the actual parameters, and code and stack space is saved.

#### Redundant pointer-load elimination

In certain situations, Turbo Pascal's code generator can eliminate redundant pointer-load instructions, shrinking the size of the code and allowing for faster execution. When the code generator can guarantee that a particular pointer remains *constant* over a stretch of linear code (code with no jumps into it), and when that pointer is already loaded into a register pair (such as ES:DI), the code generator eliminates additional redundant pointer-load instructions in that block of code.

A pointer is considered constant if it's obtained from a variable parameter (variable parameters are always passed as pointers) or from the variable reference of a **with** statement. Because of this, using **with** statements is often more efficient (but never less efficient) than writing the fully-qualified variable for each component reference.

#### Constant set inlining

When the right operand of the **in** operator is a set constant, the compiler generates the inclusion test using inline eMP instructions. Such inlined tests are more efficient than the code that would be generated by a corresponding boolean expression using relational operators. For example, this statement:

|if||'Z'))|
|---|---|---|
|((Ch >= 'A')|and (Ch <=|or|
|((Ch >=|and (Ch <=|then|

##### 'a') 'z')) ... i

is less readable and also less efficient than this:

if Ch in [' A' .. ' Z',, a' .. ' z ' 1 then ... *i*

Because constant folding applies to set constants as well as to constants of other types, it's possible to use **const** declarations without any loss of efficiency:

*Chapter* 27, *Optimizing your code*

const

|Upper = ['|A' .. ' Z '];||||
|---|---|---|---|---|
|Lower = ['a'|..||||
|Alpha = Upper|Lower;||||
|these declarations,||this|if statement|the same|
|as the previous||if statement:|||
|Ch in Alpha|then||||

'z']; +

Given generates code

if ...

**sets**

|The compiler|generates|very efficient|code for|operations|on small|
|---|---|---|---|---|---|
|sets. A small|set is a set|with a lower|bound ordinal|value|in the|
|range 0 .. 7|and an|bound ordinal|value|in the range|0 .. 15.|
|For example,|the following|TByteSet|and TWordSet|are|both small|

upper

sets.

type TByteSet = set of 0 .. 7; TWordSet = set of O .. 15;

Small set operations, such as union (+), difference (-), intersection

(*), and inclusion tests (in) are generated inline using AND, OR, NOT, and TEST machine code instructions instead of calls to run- time library routines. Likewise, the *Include* and *Exclude* standard procedures generate inline code when applied to small sets.
##### Order of evaluation

As permitted by the Pascal standards, operands of an expression are frequently evaluated differently from the left to right order in which they are written. For example, the statement

I := F(J) div G(J);

where F and G are functions of type *Integer,* causes G to be eval- uated before F, because this enables the compiler to produce better code. For this reason, it's important that an expression never depend on any specific order of evaluation of the embed- ded functions. Referring to the previous example, if F must be called before G, use a temporary variable:

*Language Guide*

~

|. As an exception|to this|rule, when|short-circuit|evaluation|is||
|---|---|---|---|---|---|---|
|enabled|{$B-} state),|Boolean|operands|grouped|with and|or|
|or are always|evaluated|from left|to right.||||

(the

#### Range checking

Assignment of a constant to a variable and use of a constant as a value parameter is range-checked at compile time; no run-time range-check code is generated. For example, X : = 999, where X is of type *Byte,* causes a compile-time error.

#### Shift instead of multiply or divide

The operation X * C, where C is a constant and a power of 2, is coded using a SHL instruction. The operation X **div** C, where X is an unsigned integer *(Byte* or *Word)* and C is a constant and a power of 2, is coded using a SHR instruction.

Likewise, when the size of an array's components is a power of 2, a SI1L instruction (not a MUL instruction) is used to scale the index expression.

#### Automatic word alignment

|By default,|Turbo Pascal|aligns|all variables|and typed|constants||
|---|---|---|---|---|---|---|
|larger than|1 byte on|a machine-word|boundary.|On|all 16-bit||
|80x86 CPUs,|word alignment|means|faster|execution,|because||
|word-sized words on|items addresses.|even addresses|are accessed|faster|than||
|Data alignment|is controlled|through|the $A|compiler|directive.|In|
|the default|{$A+} state,|variables|and typed|constants|are aligned||
|as described|above.|In the {$A-}|state, no alignment||measures|are|

on odd

|For more|details, refer|to|
|---|---|---|
|Chapter|2, "Compiler||
|directives,"||in the|
|Programmer's|Reference.||

taken.

*Chapter* 21, *Optimizing your code*

Statements that never execute don't generate any code. For example, these constructs don't generate any code:

##### if False then

statement while False do statement

#### Smart linking

|When compiling|to memory,||
|---|---|---|
|Turbo Pascal's|smart|linker is|
|disabled.|This explains|why|
|some programs|become||
|smaller when|compiled|to|
|||disk.|

Turbo Pascal's built-in linker automatically removes unused code and data when building an .EXE file. Procedures, functions, vari-' ables, and typed constants that are part of the compilation, but are never referenced, are removed from the .EXE file. The removal of unused code takes place on a per procedure basis; the removal of unused data takes place on a per declaration section basis.

##### Consider the following program:

program SmartLink;

const H: array[O .. 15] of Char = '0123456789ABCDEF';

var I, J: Integer; X, Y: Real;

var S: string[79];

var A: array[l .. 10000] of Integer;

procedure P1 *i* begin A[l] := 1; end;

procedure P2; begin I : = 1; end;

*Language Guide*

S .-'Turbo Pascal'; P2; *endj*

begin P3; end.

so

|The main|program calls|P3, which|calls P2,|both P2|and P3 are|
|---|---|---|---|---|---|
|included|in the .EXE|file. Because|P2 references|the first|var|
|declaration|section,|and P3 references|the second|var declaration,||
|I, /, X, Y,|and S are also|included|in the .EXE|file. No references||
|are made|to Pl, however,|and none|of the included|procedures||
|reference|H and A, so|these objects|are removed.|||
|Smart linking|is especially|valuable|in connection|with|units that|
|implement|procedure/|function|libraries. An|example|of such a|
|unit is the|Dos standard|unit:|contains a number|of procedures||
|and functions,|all of|which are seldom|used|by the same|program.|
|a program|uses only|one or two|procedures|from Dos,|then only|
|these procedures|are|included in|the final.EXE|file, and|the re-|
|maining|ones are removed,|greatly|reducing|the size of|the .EXE|

It

If

file.

*Chapter* 21, *Optimizing your code*

Pascal's built-in assembler allows you to write 8086/8087 and 80286/80287 assembler code directly inside your Pascal programs. Of course, you can still convert assembler instructions to machine code manually for use in **inline** statements, or link in .OBJ files that contain **external** procedures and functions when you want to mix Pascal and assembler.

The built-in assembler implements a large subset of the syntax supported by Turbo Assembler and Microsoft's Macro Assembler. The built-in assembler supports all 8086/8087 and 80286/80287 opcodes, and all but a few of Turbo Assembler's expression operators.

Except for DB, DW, and DD (define byte, word, and double word), none of Turbo Assembler's directives, such as EQU, PROC, STRUC, SEGMENT, and MACRO, are supported by the built-in assembler. Operations implemented through Turbo Assembler directives, however, are largely matched by corresponding Turbo Pascal constructs. For example, most EQU directives correspond to const, var, and **type** declarations in Turbo Pascal, the PROC directive corresponds to **procedure** and **function** declarations, and the STRUC directive corresponds to Turbo Pascal **record** types. In fact, Turbo Pascal's built-in assembler can be thought of as an assembler language compiler that uses Pascal syntax for all declarations.

*Chapter* 22, *The built-in assembler*

the rest of the line is a com- ment-comments must be written in Pascal style using { and} or (* and *).

|In general,|the rules|of register|use in|an asm statement|are|the|
|---|---|---|---|---|---|---|
|same as|those of an|external|procedure|or function.|An asm|state-|
|ment must|preserve|the BP,|SP, SS, and|DS registers,||can|
|freely modify|the|AX, BX, CX,|DX, SI,|DI, ES, and|Flags registers.||
|On entry|to an asm|statement,|BP points|to the|current stack||
|frame, SP|points to|the top|of the stack,|SS contains|the segment||
|address|of the stack|segment,|and DS|contains the|segment||
|address|of the data|segment.|Except for|BP, SP,|SS, and DS,||
|8sm statement entry to|can the statement.|assume|nothing about|register|contents|on|

but

an

##### Assembler statement syntax

This is the syntax of an assembler statement:

[ Label ":" 1 < Prefix> [ Opcode [ Operand < "," Operand> 1 1

*Label* is a label identifier, *Prefix* is an assembler prefix opcode (operation code), *Opcode* is an assembler instruction opcode or directive, and *Operand* is an assembler expression.

Comments are allowed between assembler statements, but not within them. For example, this is allowed:

*Language Guide*

asm MOV AX,l {Initial value} MOV CX,lOO {Count} end;

|but this is|an error:||
|---|---|---|
|asm|||
|MOV|value}|AX,l;|
|MOV CX, end;|{Count} 100|-|

{Initial

*Only the first* 32 *characters of* Labels are defined in assembler as they are in Pascal-by writing *an identifier are significant in* a label identifier and a colon before a statement. And as they are *the built-in assembler.* in Pascal, labels defined in assembler must be declared in a label declaration part in the block containing the asm statement. There is one exception to this rule: *local labels.*

Local labels are labels that start with an at-sign (@). Because an at-sign can't be part of a Pascal identifier, such local labels are automatically restricted to use within asm statements. A local label is known only within the asm statement that defines it (that is, the scope of a local label extends from the asm keyword to the end keyword of the asm statement that contains it).

Unlike a normal label, a local label doesn't have to be declared in a label declaration part before it's used.

The exact composition of a local label identifier is an at-sign (@) followed by one or more letters *(A .. Z),* digits (0 .. 9), underscores

(_), or at-signs. As with all labels, the identifier is followed by a colon (:).
Instruction

opcodes The built-in assembler supports all 8086/8087 and 80286/80287 instruction opcodes. 8087 opcodes are available only in the {$N+} state (numeric processor enabled), 80286 opcodes are available only in the {$G+} state (80286 code generation enabled), and 80287 opcodes are available only in the {$G+,N+} state.

For a complete description of each instruction, refer to your 80x86 and 80x87 reference manuals.

*Chapter* 22, *The built-in assembler*

On the other hand, the RETN and RETF instructions always generate a near return and a far return, regardless of the call model of the current procedure or function.

Automatic jump sizing Unless otherwise directed, the built-in assembler optimizes jump instructions by automatically selecting the shortest, and therefore most efficient form of a jump instruction. This automatic jump sizing applies to the unconditional jump instruction OMP), and all conditional jump instructions, when the target is a label (not a procedure or function).

For an unconditional jump instruction OMP), the built-in assembler generates a short jump (one byte opcode followed by a one byte displacement) if the distance to the target label is within -128 to 127 bytes; otherwise a near jump (one byte opcode followed by a two byte displacement) is generated.

For a conditional jump instruction, a short jump (1 byte opcode followed by a 1 byte displacement) is generated if the distance to the target label is within-128 to 127 bytes; otherwise, the built-in assembler generates a short jump with the inverse condition, which jumps over a near jump to the target label (5 bytes in total). For example, the assembler statement

JC Stop

where *Stop* isn't within reach of a short jump is converted to a machine code sequence tha,t corresponds to this:

*Language Guide*

JNC Skip JMP Stop Skip:

Jumps to the entry points of procedures and functions are always either near or far, but never short, and conditional jumps to procedures and functions are not allowed. You can force the built-in assembler to generate an unconditional near jump or far jump to a label by using a NEAR PTR or FAR PTR construct. For example, the assembler statements

JMP NEAR PTR Stop JMP FAR PTR Stop

always generate a near jump and a far jump, respectively, even if *Stop* is a label within reach of a short jump.

##### directives Turbo Pascal's built-in assembler supports three assembler

|directives:|DB (define|byte),|DW (define|word),|and DD (define||
|---|---|---|---|---|---|---|
|double|word). They|each generate|data|corresponding|to|the|
|comma-separated||operands|that follow|the directive.|||
|The DB|directive|generates|a sequence|of bytes.|Each operand|can|
|be a constant|expression|with|a value|between-128|and 255,|or a|
|character|string of|any length.|Constant|expressions|generate|one|
|byte of|code, and|strings generate|a sequence|of|bytes with|values|
|corresponding|to|the ASCII|code of each|character.|||
|The DW|directive|generates|a sequence|of words.|Each operand||
|can be a|constant|expression|with a value|between|-32,768|and|
|65,535,|or an address|expression.|For|an address|expression,|the|
|built-in|assembler|generates|a near pointer,|that|is, a word|that|
|contains|the offset|of the|address.||||
|The DD|directive|generates|a sequence|of double|words.|Each|
|operand|can be a|constant|expression|with a value|between||
|-2,147,483,648|and|4,294,967,295,|or an|address|expression.|For an|
|address|expression,|the built-in|assembler|generates|a far|pointer,|
|that is,|a word that|contains|the offset|part of the|address,||
|followed|by a word|that contains|the|segment part|of the|address.|
|The data|generated|the|DB, DW, and|DD directives|is always||
|stored in|the code|segment,|just like the|code generated|by|other|
|built-in|assembler|statements.|To generate|uninitialized|or|initial-|
|ized data|in the data|segment,|you should|use Pascal|var|or canst|

directives: DB (define byte), DW (define word), and DD (define

part

by

declarations.

*Chapter* 22, *The built-in assembler*

|OFFH||{One byte|}|
|---|---|---|---|
|DB 0,99||{Two bytes|}|
|DB 'A'||{Ord('A')|}|
|DB 'Hello|followed|by CR/LF|}|
|DB 12,|{Pascal||}|
|DW OFFFFH||{One word|}|
|DW 0,9999||{Two words|}|
|DW 'A'|Same|as DB 'A',O|}|
|DW 'BA'|Same as|DB 'A',|'B'}|
|DW MyVar|{Offset|of MyVar|}|
|DW MyProc|{Offset|of MyProc|}|
|DD OFFFFFFFFH|{One|double-word|}|
|DD 0,999999999|{Two|double-words|}|
|DD 'A'|Same as|DB 'A' ,0,0,0|}|
|DD 'DCBA'|as DB 'A',|'B',|'D'}|
|DD MyVar|{Pointer|to MyVar|}|
|DD MyProc end;|{Pointer|to MyProc|}|

world ... ' ,ODH,OAH String "Turbo Pascal" style string

Same 'C',

**In Turbo Assembler, when an identifier precedes a DB, DW, or DD** **directive, it causes the declaration of a byte, word, or double-** **word sized variable at the location of the directive. For example, following:**

|Turbo Assembler|allows|the|
|---|---|---|
|ByteVar|DB||
|WordVar|DW||
||MOV|AL,ByteVar|
||MOV|BX,WordVar|

##### The built-in assembler doesn't support such variable declarations.

##### In Turbo Pascal, the only kind of symbol that can be defined in an

**built-in assembler statement is a label. All variables must be de- clared using Pascal syntax, and the preceding construct corre-**

##### sponds to this:

**var** ByteVar: Byte; WordVar: Word;

**asm** MOV AL,ByteVar MOV BX,WordVar **end;**

***Language Guide***

|Built-in|assembler|operands|are|expressions|that|consist|of|a|
|---|---|---|---|---|---|---|---|---|
|combination|of|constants,|registers,|symbols,|and|operators.|||
|Although|built-in|assembler|expressions||are built|using|the|same|
|basic|principles|as Pascal|expressions,|there|are|a number||of|
|important|differences,|as|will be|explained|later|in this|chapter.||
|Within meaning|operands, to the|the following built-in assembler:||reserved|words|have|a predefined||
|AH||CS||LOW|||SI||
|AL||CX||MOD|||SP||
|AND||DH||NEAR|||SS||
|AX||DI||NOT|||ST||
|BH||DL||OFFSET|||TBYTE||
|BL||DS||OR|||TYPE||
|BP||DWORD||PTR|||WORD||
|BX||DX||QWORD|||XOR||
|BYTE||ES||SEG|||||
|CH||FAR||SHL|||||
|CL||HIGH||SHR|||||

Table 22.1

Built-in assembler reseNed words

The reserved words always take precedence over user-defined identifiers. For example, the code fragment

var ch: Char;

asm MOV CH, 1 end;

loads 1 into the CH register, *not* into the CH variable. To access a user-defined symbol with the same name as a reserved word, you must use the ampersand (&) identifier override operator:

asm MOV &ch, 1 end;

It's strongly suggested that you avoid user-defined identifiers with the same names as built-in assembler reserved words, because such name confusion can easily lead to obscure and hard-to-find bugs..

*Chapter* 22, *The built-in assembler*

The built-in assembler evaluates all expressions as 32-bit integer values; it doesn't support floating-point and string values, except string constants.

Built-in assembler expressions are built from *expression elements* and *operators,* and each expression has an associated *expression* *class* and *expression type.* These concepts are explained in the following sections.

Pascal The most important difference between Pascal expressions and built-in assembler expressions is that all built-in assembler expres- and Assembler sions must resolve to a *constant value,* a value that can be expressionscomputed at compile time. For example, given these declarations:

const X = 10; Y = 20; var Z: Integer;

the following is a valid built-in assembler statement:

asm MOV Z,X+Y end;

Because both X and Yare constants, the expression X + Y is merely a more convenient way of writing the constant 30, and the resulting instruction becomes a move immediate of the value 30 into the word-sized variable Z. But if you change X and Y to be variables,

var x, Y: Integer;

the built-in assembler can no longer compute the value of X + Yat compile time. The correct built-in assembler construct to move the sum of X and Y into Z is this:

asm MOV *l\t.,X* ADD *l\t.,Y* MOV *Z,l\t.* end;

*Language Guide*

Another important difference between Pascal and built-in assembler expressions is the way variables are interpreted. In a Pascal expression, a reference to a variable is interpreted as the *contents* of the variable, but in an built-in assembler expression, a variable reference denotes the *address* of the variable. For example, in Pascal, the expression X + 4, where X is a variable, means the contents of X *plus* 4, whereas in the built-in assembler it means the contents of the word at an address four bytes higher than the address of X. So, even though you're allowed to write

asm MOV AX,X+4 end;

the code doesn't load the value of X plus 4 into AX, but rather it loads the value of a word stored four bytes beyond X. The correct way to add 4 to the contents of X is:

asm MOV AX,X ADD AX,4 end;

**elements** The basic elements of an expression are *constants, registers,* and *symbols.*

Constants The built-in assembler supports two types of constants: *numeric* *constants* and *string constants.*

##### Numeric constants

Numeric constants must be integers, and their values must be between-2,147,483,648 and 4,294,967,295.

By default, numeric constants use decimal (base 10) notation, but the built-in assembler supports binary (base 2), octal (base 8), and hexadecimal (base 16) notations as well. Binary notation is se- lected by writing a *B* after the number, octal notation is selected by writing a letter 0 after the number, and hexadecimal notation is selected by writing an H after the number or a $ before the number.

*Chapter* 22, *The built-in assembler*

#### ~ The B, 0, and H suffixes aren't supported in Pascal expressions.

Pascal expressions allow only decimal notation (the default) and hexadecimal notation (using a $ prefix).

Numeric constants must start with one of the digits 0 through 9 or a $ character; therefore, when you write a hexadecimal constant using the H suffix, an extra zero in front of the number is required if the first significant digit is one of the hexadecimal digits *A* through *F.* For example, OBAD4H and $BAD4 are hexadecimal constants, but BAP4H is an identifier because it starts with a letter and not a digit.

##### String constants

String constants must be enclosed in single or double quotes. Two consecutive quotes of the same type as the enclosing quotes count as only one character. Here are some examples of string constants:

'Z' 'Turbo Pascal' "That's all folks" '"That"s all folks," he said.' '100'

Notice in the fourth string the use of two consecutive single quotes to denote one single quote character.

String constants of any length are allowed in DB directives, and cause allocation of a sequence of bytes containing the ASCII values of the characters in the string. In all other cases, a string constant can be no longer than four characters, and denotes a numeric value which can participate in an expression. The numeric value of a string constant is calculated as

Ord(Ch1) + Ord(Ch2) shl 8 + Ord(Ch3) shl 16 + Ord(Ch4) shl 24

where *Chl* is the rightmost (last) character and *Ch4* is the leftmost (first) character. If the string is shorter than four characters, the leftmost (first) character(s) are assumed to be zero. Here are some examples of string constants and their corresponding numeric values:

*Language Guide*

**String Value**

|'a'|0OOOO061H|
|---|---|
|'ba'|00006261H|
|'eba'|00636261H|
|'deba'|64636261H 00OO6120H|
|, a'|20202061H|
|'a'*2|OOOOOOE2H|
|'a'-'A'|00OOO020H|
|'a'|FFFFFF9EH|
|The following|reserved|

'a'

**not**

Registers symbols denote CPU registers:

|CPU Table registers 22.3|16-bit general||AX|BX||DX|
|---|---|---|---|---|---|---|
||8-bit low|registers|AL|BL|CL|DL|
||8-bit high|registers||BH|||
||16-bit pointer|index|5P|BP|51|DI|
||16-bit segment 8087 register|registers staek|C5 ST|D5|55|E5|

purpose ex

AH CH DH or

When an operand consists solely of a register name, it's called a register operand. All registers can be used as register operands. In addition, some registers can be used in other contexts.

The base registers (BX and BP) and the index registers (SI and DI) can be written within square brackets to indicate indexing.-Valid base/index register combinations are [BX], [BP], lSI], [DI], [BX+SI], [BX+DI], [BP+SI], and [BP+DI].

The segment registers (ES, CS, SS, and DS) can be used in con- junction with the colon (:) segment override operator to indicate a different segment than the one the processor selects by default.

The symbol ST denotes the topmost register on the 8087 floating- point register stack. Each of the eight floating-point registers can be referred to using *ST(x),* where *x* is a constant between 0 and 7 indicating the distance from the top of the register stack.

Symbols The built-in assembler allows you to access almost all Pascal symbols in assembler expressions, including labels, constants, types, variables, procedures, and functions. In addition, the built- in assembler implements the following special symbols:

##### @Code @Data @Result

*Chapter* 22, *The built-in assembler*

MOV AX,SEG @Data MOV DS,AX end;

The *@Result* symbol represents the function result variable within For example, in this function:

|the statement|part|of a function.|
|---|---|---|
|function begin Sum := end;|Sum (X, X + Y;|Y: Integer):|

Integer;

the statement that assigns a function result value to *Sum* would it was written in built-in assembler:

|use the @Result|variable|if|
|---|---|---|
|function begin asm|Sum(X,|Y: Integer):|
|MOV|AX,X||
|ADD|AX,Y||
|MOV end; end;|@Result,AX||

Integer;

The following symbols can't be used in built-in assembler expressions:

- Standard procedures and functions (for example, *WriteLn, Chr)*
- The *Mem, MemW, MemL, Port,* and *PortW* special arrays
- String, floating-point, and set constants
- Procedures and functions declared with the **inline** directive
- Labels that aren't declared in the current block
- The *@Result* symbol outside a function
Table 22.4 summarizes the value, class, and type of the different
 kinds of symbols that can be used in built-in assembler expressions. (Expression classes and types are described in a following section.)
*Language Guide*

22.4
Values, classes, and types of **Symbol Value Class Type** symbols Label Address of label Memory SHORT Constant Value of constant Immediate 0 Type 0 Memory Size of type Field Offset of field Memory Size of type Variable Address of variable Memory Size of type Procedure Address of procedure Memory NEAR or FAR Function Address of function Memory NEAR or FAR Unit 0 Immediate 0 @Code Code segment address Memory OFFFOH @Data Data segment address Memory OFFFOH @Result Result var offset Memory Size of type

Local variables (variables declared in procedures and functions) are always allocated on the stack and accessed relative to SS:BP, and the value of a local variable symbol is its signed offset from SS:BP. The assembler automatically adds **[BP]** in references to local variables. For example, given these declarations,

procedure Test; var Count: Integer;

the instruction

asm

|MOV|AX, Count||
|---|---|---|
|end;|||
||MOV|AX, [BP-2l.|

assembles into

The built-in assembler always treats a **var** parameter as a 32-bit pointer, and the size of a **var** parameter is always 4 (the size of a 32-bit pointer). In Pascal, the syntax for accessing a **var** parameter and a value parameter is the same-this isn't the case in code you write for the built-in assembler. Because **var** parameters are really pointers, you have to treat them as such. So, to access the contents of a **var** parameter, you first have to load the 32-bit pointer and then access the location it points to. For example, if the X and Y parameters of the above function *Sum* were **var** parameters, the

|would code|look like|this:|
|---|---|---|
|function begin|Sum(var X,|Y: Integer):|
|LES|BX,X||
|MOV|AX,ES:|[BXj|
|LES|BX,Y||

Integer;

asm

*Chapter* 22, *The built-in assembler*

AY., ES: [BX] MOV @Result,AX **end;** **end;**

**Some symbols, such as record types and variables, have a scope** **that can be accessed using the period (.) structure member selector operator. For example, given these declarations:**

**type** TPoint = **record** X, Y: Integer; **end;** TRect = **record** A, B: TPoint; **end;** **var** P: TPoint; R: TRect;

**the following constructs can be used to access fields in the P and R variables:**

**asm** MOV AY.,P.X MOV DX,P.Y MOV CX,R.A.X MOV BX,R.B.Y **end;**

A **type identifier can be used to construct variables on the fly.** **Each of the following instructions generates the same machine code, which loads the contents of ES:[DI+4] into AX:**

**asm** MOV AX, (TRect PTR ES: [DI]) .B.X

|MOV|AX, (TRect|PTR ES: [DI])|.B.X|
|---|---|---|---|
|MOV|AX,TRect(ES:|[DI]) .B.X||
|MOV|AX,ES:TRect[DI]|.B.X||
|MOV|AY.,TRect[ES:DI]|.B.X||
|MOV end;|AX,ES: [DI]|.TRect.B.X||

|A scope|is provided|by type,|field, and|variable|symbols|of a|
|---|---|---|---|---|---|---|
|record or|object type.|In addition,|a unit|identifier|opens|the scope|
|of a particular|unit,|just like|a fully qualified|identifier|in|Pascal.|

***Language Guide***

classes

##### The built-in assembler divides expressions into three classes:

##### registers, memory references, and immediate values.

An expression that consists solely of a register name is a register expression. Examples of register expressions are AX, CL, DI, and ES. Used as operands, register expressions direct the assembler to generate instructions that operate on the CPU registers.

##### Expressions that denote memory locations are memory refer-

##### ences; Pascal's labels, variables, typed constants, procedures, and

##### functions belong to this category.

##### Expressions that aren't registers and aren't associated with

memory locations are immediate values; this group includes Pascal's untyped constants and type identifiers.

Immediate values and memory references cause different code to be generated when used as operands. For example,

const Start = 10; var Count: Integer;

asm MOV AX, Start { MOV AX,xxxx }

|MOV|AX,|{MOV AX,xxxx|}|
|---|---|---|---|
|MOV|BX,Count|{MOV BX,|[xxxx]|
|MOV|CX, [Start]|{MOV CX,|[xxxx]|
|MOV end;|DX,OFFSET|{MOV DX,xxxx|}|

Count

Because *Start* is an immediate value, the first MOV is assembled into a move immediate instruction. The second MOV, however, is translated into a move memory instruction, as *Count* is a memory reference. In the third MOV, the square brackets operator is used to convert *Start* into a memory reference (in this case, the word at offset 10 in the data segment), and in the fourth MOV, the OFFSET operator is used to convert *Count* into an immediate value (the offset of *Count* in the data segment).

As you can see, the square brackets and the OFFSET operators complement each other. In terms of the resulting machine code, the following **asm** statement is identical to the first two lines of the previous **asm** statement:

*Chapter* 22, *The built-in assembler*

|MOV|AX,OFFSET|[Start]|
|---|---|---|
|MOV end;|BX, [OFFSET|Count]|

Memory references and immediate values are further classified as either *relocatable expressions* or *absolute expressions.* A relocatable expression denotes a value that requires *relocation* at link time, and an absolute expression denotes a value that requires no such relocation. Typically, an expression that refers to a label, variable, procedure, or function is relocatable, and an expression that operates solely on constants is absolute.

Relocation is the process by which the linker assigns absolute addresses to symbols. At compile time, the compiler doesn't know the final address of a label, variable, procedure, or function; it doesn't become known until link time, when the linker assigns a specific absolute address to the symbol.

The built-in assembler allows you to carry out any operation on an absolute value, but it restricts operations on relocatable values to addition and subtraction of constants.

Every built-in assembler expression has an associated type-or more correctly, an associated size, because the built-in assembler regards the type of an expression simply as the size of its memory location. For example, the type (size) of an *Integer* variable is two, because it occupies 2 bytes.

The built-in assembler performs type checking whenever possible, so in the instructions

var QuitFlag: Boolean; OutBufPtr: Word;

asm MOV AL,QuitFlag MOV BX,OutBufPtr end;

the built-in assembler checks that the size of *QuitFlag* is one (a byte), and that the size of *OutBufPtr* is two (a word). An error results if the type check fails. For example, this isn't allowed:

*Language Guide*

MOV DL,OutBufPtr end;

The problem is DL is a byte-sized register and *OutBufPtr* is a word. The type of a memory reference can be changed through a typecast; these are correct ways of writing the previous instruction:

|asm|||
|---|---|---|
|MOV|DL,BYTE|PTR OutBufPtr|
|MOV|DL, Byte|(OutBufPtr)|
|MOV|DL,OutBufPtr.Byte||
|end;|||

all of which refer to the first (least significant) byte of the *OutBufPtr* variable.

In some cases, a memory reference is untyped, that is, it has no associated type. One example is an immediate value enclosed in square brackets:

asm MOV AL, [IOOR] MOV BX, [IOOR] end;

The built-in assembler permits both of these instructions, because the expression [100H] has nq associated type-it just means "the contents of address 100H in the data segment," and the type can be determined from the first operand (byte for AL, word for BX). In cases where the type can't be determined from another requires an explicit typecast:

|operand,|the built-in|assembler|
|---|---|---|
|asm|||
|INC|BYTE PTR|[IOOR]|
|IMUL end;|WORD PTR|[IOOR]|

Table 22.5 summarizes the predefined type symbols that the

built-in assembler provides in addition to any currently declared Pascal types.

*Chapter* 22, *The built-in assembler*

|22.5|||
|---|---|---|
|type symbols|Symbol|Type|
||BYTE WORD DWORD aWORD TBYTE|2 4 8 10|
||NEAR||
||FAR||

Predefined 1

OFFFEH OFFFFH

Notice in particular the NEAR and FAR pseudotypes, which are used by procedure and function symbols to indicate their call model. You can use NEAR and FAR in typecasts just like other symbols. For example, if *FarProc* is a FAR procedure,

procedure FarProc; far;

and if you are writing built-in assembler code in the same module as *FarProc,* you can use the more efficient NEAR call instruction to call it:

|asm|||
|---|---|---|
|PUSH|CS||
|CALL|NEAR PTR|FarProc|
|end;|||

Expression

operators The built-in assembler provides a variety of operators, divided into 12 classes of precedence. Table 22.6 lists the built-in assembler's expression operators in decreasing order of precedence.

Table 22.6

Summary of built-in Operator(s) Comments asssembler expression & Identifier override operator operators 0, [], •Structure member selector

*Built-in assembler operator* HIGH, LOW *precedence is different from* *Pascal. For example, in* a +,-Unary operators *built-in assembler expression,* Segment override operator *the AND operator has lower* *precedence than the plus*OFFSE~SEG,TYPE,PTR,

(+) *and minus* (-) *operators,* *, *I,* MOD, SHL, SHR *whereas in* a *Pascal*
##### +,-Binary addition/ subtraction

*expression, it has higher* operators *precedence.* NOT, AND, OR, XOR Bitwise operators

*Language Guide*

|22.7:|Definitions|of built-in|
|---|---|---|
|Operator|Description||
|&|Identifier|override.|

assembler expression operators

The identifier immediately following the ampersand is treated as a user-defined symbol, even if the spelling is the same as a built-in assembler reserved symbol. ( ... ) **Subexpression.** Expressions within parentheses are evaluated completely prior to being treated as a single expression element. Another expression can optionally precede the expression within the parentheses; the result in this case becomes the sum of the values of the two expressions, with the type of the first expression. [ ...] **Memory reference.** The expression within brackets is evaluated completely prior to being treated as a single expression element. The expression within brackets can be combined with the BX, BP, sr, or Dr registers using the plus (+) operator, to indicate CPU register indexing. Another expression can optionally precede the expression within the brackets; the. result in this case becomes the sum of the values of the two expressions, with the type of the first expression. The result is always a memory reference. **Structure member selector.** The result is the sum of the expression before the period and the expression after the period, with the type of the expression after the period. Symbols belonging to the scope identified by the expression before the period can be accessed in the expression after the period. **HIGH** Returns the high-order 8 bits of the word-sized expression following the operator. The

||expression|must|
|---|---|---|
|LOW|||
|+|Unary Unary Segment|plus. minus. override.|

be an absolute immediate value. Returns the low-order 8 bits of the word-sized expression following the operator. The expression must be an absolute immediate value. Returns the expression following the plus with no changes. The expression must be an absolute immediate value. Returns the negated value of the expression following the minus. The expression must be an absolute immediate value. Instructs the assembler that the expression after the colon belongs to the segment given by the segment register name (CS, DS, SS, or ES) before the colon. The result is a memory reference with the value of the expression after the colon. When a segment override is used in an instruction operand, the instruction will be prefixed by an appropriate segment override prefix instruction to ensure that the indicated segment is selected. **OFFSET** Returns the offset part (low-order word) of the expression following the operator. The result is an immediate value. **SEG** Returns the segment part (high-order word) of the expression following the operator. The result is an immediate value. **TYPE** Returns the type (size in bytes) of the expression following the operator. The type of an immediate value is O. ' **PTR Typecast operator.** The result is a memory reference with the value of the expression following the operator and the type of the expression in front of the operator. **Multiplication.** Both expressions must be absolute immediate values, and the result is an * absolute immediate value.

*Chapter* 22, *The built-in assembler*

operators (continued)

|22.7:|Definitions|of built-in|assembler|expression|
|---|---|---|---|---|
||Integer|division.|||
|MOD|Remainder|after|integer|division.|
|SHL|Logical|shift left.|||
|SHR +|Logical Addition.|shift right.|||

Both expressions must be absolute immediate values, and the result is an absolute immediate value. Both expressions must be absolute immediate values, and the result is an absolute immediate value. Both expressions must be absolute immediate values, and the result is an absolute immediate value. Both expressions must be absolute immediate values, and the result is an absolute immediate value. The expressions can be immediate values or memory references, but only one of the expressions can be a relocatable value. If one of the expressions is a relocatable value, the result is also a relocatable value. If either of the expressions are memory references, the

||result|is also a|
|---|---|---|
||Subtraction.||
|NOT|Bitwise|negation.|
|AND|Bitwise|AND.|
|OR|Bitwise|OR.|
|XOR|Bitwise|exclusive|

memory reference. The first expression can have any class, but the second expression must be an absolute immediate value. The result has the same class as the first expression. The expression must be an absolute immediate value, and the result is an absolute immediate value. Both expressions must be absolute immediate values, and the result is an absolute immediate value. Both expressions must be absolute immediate values, and the result is an absolute immediate value. **OR.** Both expressions must be absolute immediate values, and the result is an absolute immediate value.

##### Assembler procedures and functions

So far, every **asm ... end** construct you've seen has been a statement within a normal **begin ... end** statement part. Turbo Pascal's assembler directive allows you to write complete procedures and functions in built-in assembler, without the need for a **begin ... end** statement part. Here's an example of an

|assembler|function:||
|---|---|---|
|function asm|LongMul(X,|Y: Integer):|
|MOV|AX,X||
|IMUL end; assembler|Y||

Longint; assembler;

The directive causes Turbo Pascal to perform a number of code generation optimizations:

*Language Guide*

The compiler doesn't generate code to copy value parameters into local variables. This affects all string-type value param- eters, and other value parameters whose size isn't I, 2, or 4 bytes. Within the procedure or function, such parameters must be treated as if they were **var** parameters.

- The compiler doesn't allocate a function result variable, and a reference to the *@Result* symbol is an error. String functions, however, are an exception to this rule-they always have a *@Result* pointer that is allocated by the caller.
- The compiler generates no stack frame for procedures and functions that aren't nested and have no parameters and no local variables.
- The automatically generated entry and exit code for an assembler procedure or function looks like this: PUSH BP jPresent if Locals <> a or Params <> 0 MOV BP,SP jPresent Locals <> or Params <> 0

||||if||a||||
|---|---|---|---|---|---|---|---|---|
|SUB|SP,Locals|jPresent|Locals|<>|||||
|MOV|SP,BP|jPresent|Locals|<>|||||
|POP|BP|jPresent|Locals|<>|or|Params|<>||
|RET|Params|jAlways|present||||||
 SUB SP,Locals jPresent if Locals <> a
if a if a a

- *Locals* is the size of the local variables, and *Params* is the size of the parameters. If both *Locals* and *Params* are zero, there is no entry code, and the exit code consists simply of a RET instruction. Functions using the **assembler** directive must return their results as follows:
- Ordinal-type function results (integer, boolean, enumerated types, and *Char)* are returned in AL (8-bit values), AX (16-bit values), or DX:AX (32-bit values).
- Real-type function results (type *Real)* are returned in DX:BX:AX.
- 8087-type function results (type *Single, Double, Extended,* and *Comp)* are returned in ST(O) on the 8087 coprocessor's register stack.
- Pointer-type function results are returned in DX:AX.
- String-type function results are returned in the temporary location pointed to by the *@Result* function result symbol. The **assembler** directive is in many ways comparable to the **external** directive, and **assembler** procedures and functions must obey the same rules as **external** procedures and functions. The
*Chapter* 22, *The built-in assembler*

**assembler functions.** **The first example uses an asm statement in an ordinary function** **to convert a string to upper case. Notice that the value parameter** ***Str* in this case refers to a local variable, because the compiler automatically generates entry code that copies the actual**

**parameter**

||into local|storage.|
|---|---|---|
|function begin asm CLD LEA|UpperCase|(Str: String):|
|LES|DI,@Result||
|SEGSS STOSB|LODSB||
|XOR|AH,AH||
|XCHG|AX,CX||
|JCXZ @l:|@3||
|SEGSS|LODSB||
|CMP|AL,'a'||
|JB|@2||
|CMP|AL,||
|JA|@2||
|SUB @2: STOSB|AL,20H||
|LOOP @3: end; end;|@1||

String;

SI,Str

'z'

##### The second example is an assembler version of the UpperCase

**function. In this case, *Str* isn't copied into local storage, and the function must treat *Str* as a var parameter.**

**function** UpperCase (Str: String) : String; **assembler;** **asm** PUSH DS CLD LDS SI,Str LES DI,@Result LODSB STOSB XOR AH,AH XCHG AX,CX JCXZ @3

***Language Guide***

LODSB

|CMP|AL,'a'|
|---|---|
|JB|@2|
|CMP|AL,' z'|
|JA|@2|
|SUB @2 : STOSB|AL,20H|
|LOOP @3:|@1|
|POP|DS|

**end;**

***Chapter* 22, *The built-in assembler***

Pascal programs or units using the **$L** compiler directive. The assembly language source file must be assembled into an object file (extension .OBJ) using an assembler like Turbo Assembler. Multiple object files can be linked with a program or unit through multiple **$L** directives.

Procedures and functions written in assembly language must be declared as **external** in the Pascal program or unit. For example,

function LoCase(Ch: Char): Char; external;

In the corresponding assembly language source file, all procedures and functions must be placed in a segment named CODE or CSEG, or in a segment whose name ends in _TEXT. The names of the external procedures and functions must appear in PUBLIC directives.

You must ensure that an assembly language procedure or function matches its Pascal definition with respect to call model (near or far), number of parameters, types of parameters, and result type.

An assembly language source file can declare initialized variables in a segment named CaNST or in a segment whose name ends in _DATA. It can declare uninitialized variables in a segment named DATA or DSEG, or in a segment whose name ends in _BSS. Such variables are private to the assembly language source file and can't be referenced from the Pascal program or unit. However,

*Chapter* 23, *Linking assembler code*

Pascal globals, and can be accessed through the DS segment register.

All procedures, functions, and variables declared in the Pascal program or unit, and the ones declared in the **interface** section of the used units, can be referenced from the assembly language source file through EXTRN directives. Again, it's up to you to supply the correct type in the EXTRN definition.

When an object file appears in a **$L** directive, Turbo Pascal converts the file from the Intel relocatable object module format (.OBJ) to its own internal relocatable format. This conversion is possible only if certain rules are observed:

- All procedures and functions must be placed in a segment named CODE or CSEG, or in a segment with a name that ends in _TEXT. All initialized private variables must be placed in a segment named CONST, or in a segment with a name that ends in _DATA. All uninitialized private variables must be placed in a segment named DATA or DSEG, or in a segment with a name that ends in _BSS. All other segments are ignored, and so are GROUP directives. The segment definitions can specify BYTE or WORD alignment, but when linked, code segments are always byte aligned, and data segments are always word aligned. The segment definitions can optionally specify PUBLIC and a class name, both of which are ignored.
- Turbo Pascal ignores any data for segments other than the code segment (CODE, CSEG, or *xxxx_TEXT)* and the initialized data segment (CaNST or *xxxx_DATA).* So, when declaring variables in the uninitialized data segment (DATA, DSEG, or xxxx_BSS), always use a question mark (?) to specify the value, for instance:

|Count|DW ?|
|---|---|
|Buffer|DB 128 DUP(?)|

|• Byte-sized|references|to EXTRN|symbols|aren't|allowed.|For|
|---|---|---|---|---|---|---|
|example,|this means|that the|assembly|language|HIGH|and|
|LOW|operators|be used|with EXTRN|symbols.|||

can't

##### Turbo Assembler and Turbo Pascal

Turbo Assembler (TASM) makes it easy to program routines in assembly language and interface them into your Turbo Pascal

*Language Guide*

##### Pascal programmers.

The .MODEL directive specifies the memory model for an assembler module that uses simplified segmentation. For linking with Pascal programs, the .MODEL syntax looks like this:

.MODEL XXXX, PASCAL

*xxxx* is the memory model (usually this is large).

Specifying the language PASCAL in the .MODEL directive tells Turbo Assembler that the arguments were pushed onto the stack from left to right, in the order they were encountered in the source statement that called the procedure.

The PROC directive lets you define your parameters in the same order as they are defined in your Pascal program. If you are defining a function that returns a string, notice that the PROC directive has a RETURNS option that lets you access the tempo- rary string pointer on the stack without affecting the number of parameter bytes added to the RET statement.

Here's an example coded to use the .MODEL and PROC directives:

|.MODEL|LARGE, PASCAL||||
|---|---|---|---|---|
|. CODE|||||
|PROC|FAR I : BYTE,|J : BYTE RETURNS|Result|: DWORD|
|PUBLIC|MyProc||||
|LES|DI, Result|iget address|of temporary||
|MOV|AL, I|iget|parameter|I|
|MOV RET|BL, J|iget second|parameter|J|

MyProc

string first

The Pascal function definition would look like this:

function MyProc(I, J: Char): stringi externali

For more information about interfacing Turbo Assembler with Turbo ,Pascal, refer to the *Turbo Assembler User's Guide.*

#### Examples of assembly language routines

an

|The following|code|is example|of a unit|that implements|two|
|---|---|---|---|---|---|
|assembly|language|string-handling|routines.|The UpperCase||
|function|converts|all characters|in a string|to uppercase,|and the|

*Chapter* 23, *Linking assembler code*

UpperCase(S: String): Stringi **function** StringOf(Ch: *Chari* Count: Byte): Stringi **implementation** {$L STRS} **function** UpperCasei **externali**

|segmenta|tion:||||||
|---|---|---|---|---|---|---|
|CODE|SEGMENT|BYTE PUBLIC|||||
||ASSUME|CS:CODE|||||
||PUBLIC|UpperCase,|StringOf|iMake|them known||
|function|UpperCase(S:||String):||||
|UpperRes||EQU|DWORD PTR|[BP + 10]|||
|UpperStr||EQU|DWORD PTR|[BP + 6]|||
|UpperCase||PROC FAR|||||
||PUSH|BP||iSave|BP||
||MOV|BP, SP||iSet|up stack|frame|
||PUSH|DS||iSave|DS||
||LDS|SI, Upperstr||iLoad|address||
||LES CLD LODSB STOSB|DI, Upperres||iLoad iForward iLoad iCOPY|address string-ops length to||
||MOV|CL, AL||iString|length|to CX|
||XOR|CH, CH|||||
||JCXZ|U3||iSkip|empty||
|U1:|LODSB|||iLoad|character||
||CMP JB|AL, U2||i8kip|not||
||CMP JA|AL,, z' U2|||||
||SUB|AL,||iConvert|to uppercase||
|U2:|STOSB|||iStore|in||
||LOOP|U1||iLoop|for|characters|

|function|UpperCasei|externali||
|---|---|---|---|
|function end.|StringOfi|externali||

|The assembly||language|file that|implements|the UpperCase|and|
|---|---|---|---|---|---|---|
|StringOf|routines|is shown|next.|It must be|assembled|into a file|
|called|STRS.OBJ|before|the Stringer|unit can|be compiled.|Note|
|that the|routines|use the|far call|model because|they|are declared|
|in the|interface|section|of the unit.|This example|uses|standard|

String

string result

string result

if string

##### 'a' if 'a' .. 'z'

'a'-'A' result all

***Language Guide***

DS jRestore DS BP jRestore BP RET 4 *jRemove* parameter and return

||RET|4||jRemove|parameter|and return|
|---|---|---|---|---|---|---|
|UpperCase||ENDP|||||
|procedure|StringOf(var||S: Stringi|Ch: Chari|Count: Byte}||
|StrOfS||EQU|DWORD PTR|[BP + 10]|||
|StrOfChar||EQU|BYTE PTR|[BP + 8]|||
|StrOfCount||EQU|BYTE PTR|[BP + 6]|||
|StringOf||PROC FAR|||||
||PUSH|BP||jSave|BP||
||MOV|BP, SP||jSet|up stack frame||
||LES|DI, StrOfRes||jLoad|result address||
||MOV CLD STOSB|AL, StrOfCount||iLoad jForward jStore|count string-ops length||
||MOV|CL, AL||jCount|to CX||
||XOR|CH, CH|||||
||MOV|AL, StrOfChar||iLoad|character||
||REP|STOSB||jStore|of|characters|
||POP RET|BP 8||jRestore jRemove|BP parameters|and return|
|StringOf||ENDP|||||
|CODE|ENDS||||||
||END||||||

*j*

string

##### To assemble the example and compile the unit, use the following commands:

TASM STR5 TPCW stringer

#### Assembly language methods

|Method|implementations||written|in assembly|language|can be|
|---|---|---|---|---|---|---|
|linked|with Turbo|Pascal|programs|using the|$L compiler||
|directive|and the|external|reserved|word. The|declaration|of an|
|external|method|in an object|type|is no different|than that|of a|
|normal|method;|however,|the implementation||of the method|lists|
|only the|method|header|followed|by the reserved|word|external.|
|In an|assembly|language|source text,|an is|used instead|of a|
|period|(.) to write|qualified|identifiers|(the period already||has a|
|different|meaning|in assembly|language|and|can't be part|of an|

**@**

***Chapter* 23, *Linking assembler code***

Pascal identifier *Rect.lnit* is written as *Rect@Init* in assembly language. The @ syntax can be used to declare both PUBLIC and EXTRN identifiers.

#### Inline machine code

For very short assembly language subroutines, Turbo Pascal's **inline** statements and directives are very convenient. They let you insert machine code instructions directly into the program or unit text instead of through an object file.

##### Inline statements

An **inline** statement consists of the reserved word **inline** followed by one or more inline elements, separated by slashes and enclosed in parentheses:

inline(lO/$2345/Count + l/Data-Offset);

Here's the syntax of an **inline** statement:

inline statement ~I in line element TeD-- 1----~01+-,-------'

Each inline element consists of an optional size specifier, < or >, and a constant or a variable identifier, followed by zero or more offset specifiers (see the syntax that follows). An offset specifier consists of a + or a -followed by a constant.

inline element

|Each inline|element|generates|1 byte|or 1 word|of code.|The value|
|---|---|---|---|---|---|---|
|is computed|from|the value|of the first|constant|or the offset|of the|
|variable|identifier,|to which|is added|or subtracted|the value|of|
|each of|the constants|that|follow it.||||
|An|element|generates|1 byte|of code if|consists of|con-|
|stants only|and|'if its value|is within|the 8-bit|range (0 .. 255).|the|

##### Wine it

If

*Language Guide*

value is outside the 8-bit range or if the inline element refers to a variable, 1 word of code is generated (least-significant byte first).

The < and> operators can be used to override the automatic size selection we described earlier. If an inline element starts with a < operator, only the least-significant byte of the value is coded, even if it's a 16-bit value. If an inline element starts with a > operator, a word is always coded, even though the most-significant byte is O. For example, the statement

inline«$1234/>$44);

generates 3 bytes of code: $34, $44, $00.

||BP, SP, SS,|and OS|
|---|---|---|
|must|preserved|inline|
|statements:|all other can be|registers modified.|

The value of a variable identifier in an **inline** element is the offset be *by* address of the variable within its base segment. The base segment of global variables-variables declared at the outermost level in a program or a unit-and typed constants is the data segment, which is accessible through the DS register. The base segment of local variables-variables declared within the current subpro- gram-is the stack segment. In this case the variable offset is relative to the BP register, which automatically causes the stack segment to be selected.

The following example of an **inline** statement generates machine code for storing a specified number of words of data in a specified variable. When called, procedure *FillWord* stores *Count* words of the value *Data* in memory, starting at the first byte occupied by *Dest.*

|procedure|FillWord(var|Dest; Count,|Data: Word);||
|---|---|---|---|---|
|begin|||||
||(||||
|$C4/$BE/Dest/|||{LES DI,Dest[BP]|}|
|$8B/$8E/Count!|||{MOV CX,Count[BP]|}|
|$8B/$86/Data/|||{MOV AX,Data[BP]|}|
|$FC/|||{CLD}||
|$F3/$AB); end;|||{REP STOSW|}|

inline

**Inline** statements can be freely mixed with other statements throughout the statement part of a block.

##### Inline directives

|With inline|directives,|you can|write procedures|and functions|
|---|---|---|---|---|
|that expand|into a given|sequence|of machine|code instructions|
|whenever|they are called.|These|are comparable|to macros|

in

*Chapter* 23, *Linking assembler code*

**inline** directive is the same as that of an **inline** statement:

inline directive-l inline statement ~

When a normal procedure or function is called (including one that contains **inline** statements), the compiler generates code that pushes the parameters (if any) onto the stack, and then generates a CALL instruction to call the procedure or function. However, when you call an inline procedure or function, the compiler generates code from the inline directive instead of the CALL.

|Here's a|short example|of two inline||
|---|---|---|---|
|procedure|Disablelnterruptsi|inline($FA)i|{eLI}|
|procedure|Enablelnterruptsi|inline($FB)i|{STI}|

procedures:

When *Disablelnterrupts* is called, it generates 1 byte of code-a CLI instruction.

Procedures and functions declared with inline directives can have parameters; however, the parameters can't be referred to symboli- cally in the inline directive (other variables can, though). Also, because such procedures and functions are in fact macros, there is no automatic entry and exit code, nor should there be any return instruction.

The following function multiplies two *Integer* values, producing a *Longint* result:

Longinti

|function|LongMul(X,|Y: Integer):||||
|---|---|---|---|---|---|
||(|||||
|$5A/|||POP AX iPOP|X }||
|$58/|||POP DX iPOP|Y}||
|$F7/$EA)|i||lMUL DX iDX|: AX X|Y}|

inline

= *

Note the lack of entry and exit code and the missing return instruction. These aren't required, because the 4 bytes are inserted into the instruction stream when *LongMul* is called.

Use **inline** directives for very short procedures and functions only (less than 10 bytes).

Because of the macro-like nature of **inline** procedures and func- tions, they can't be used as arguments to the @ operator and the *Addr, Ofs,* and *Seg* functions.

*Language Guide*

#### D E x

arithmetic functions *130* operations precison rules 25 A operators 68

|(pointer)|symbol|43, 56||
|---|---|---|---|
|(pound)|character|19||
|@operator|75|||
|with|a variable|75||
|with 80x87|procedures|and functions|75|
|emulation|29|||
|floating|point model|28||
|numeric|coprocessor|149-157||
|software|emulation,|selecting|28|

# array types *30, 222* variables 55 array-type constant syntax *60* arrays *30, 55* accessing elements in 31 indexing multidimensional 55 number of elements in *30* of arrays 31 valid index types in *30* zero-based character 31, 61, 169, 171 A defined 31 $A compiler directive 249 .ASM files 157 Abs function *130, 245* asm statement 256 absolute assembler clause syntax 53 code expressions, built-in assembler *270* in Turbo Pascal 255 variables 53 linked with Turbo Pascal 279 actual parameters 82 declaration syntax *101* Addr function 132 assembly language address 80x87 emulation and 157 factor 66 call model 279 functions 132 inline address-of (@) operator 43,56, 75, 79 directives 285 alignment, data 249 statements 284 ancestor of an object type 34 interfacing programs with *280* ancestors 34 linking with Turbo Pascal 279-286 and operator *70, 180* overlays and *203* AnyFile constant 162 statements apostrophes in character strings 19 multiple 256 Append procedure 135, 137, 147 syntax 256-261 Arc procedure 185 Assign procedure 135, 136, 146 Archive constant Assignert procedure 144, ArcTan function Assigned function

*Index*

Borland Graphics Interface 175-189 BP register *203,* 241, 243 brackets, in expressions 76, 77 Break procedure 87, *130* BufEnd variable *230* buffer overlay 193 loading and freeing up 194 optimization algorithm 194 probationary area 195 text, size *230* BufPtr pointer *230* BufSize variable *230* built-in assembler directives 255 expressions 262-274 classes *269-270* operators 272-274 Pascal expressions versus 262 types *270-272* instruction sizing 258-259 opcodes 257-259

|BIOS 142|||
|---|---|---|
|bit images|179||
|BitBlt|||
|operations|180||
|operators|188||
|bitmapped|fonts 178||
|bitwise operators|69||
|blanks, defined|15||
|block|||
|defined|93||
|scope|95||
|subroutine|98||
|syntax|93||
|BlockRead|procedure|135|
|BlockWrite|procedure|135|
|Boolean|||
|data type|25, 218||
|expression|evaluation|246|
|complete|70||
|short-circuit|70||
|operators|70||
|boolean|||
|data types|25||
|operators|26||
|types|218||
|variables|26||

operands 261 procedures and functions 274 registers, using 256 reserved words 261 BX register 235, 243 Byte data type 25 ByteBool data type 25, 218

C call model 279 calling conventions 233 constructors and destructors *240* methods 238 calls, near and far 236 case sensitivity of Turbo Pascal 16 statement syntax 85 CGA 175 Char data type 26, 218 character arrays 171 pair special symbols 16 pointer operators pointers characters arrays and

*Language Guide*

defined *20* $F 46, 99, 146, 198, 236 *20* $G257

|ChDir procedure|135|||
|---|---|---|---|
|CheckBreak|variable|145||
|CheckEOF|variable|145||
|CheckSnow|variable|145||
|.CHR files|175|||
|Chr function|26,|245||
|Circle procedure|185|||
|circular unit|references|121||
|Clear Device|procedure|185||
|ClearViewPort|procedure|185||
|clipping|constants|188||
|Close procedure|135,|146, 148||
|CloseGraph|procedure|176,|185|
|ClrEol procedure|144|||
|ClrScr procedure|144|||
|code segment|280|||
|procedures|and functions||in 279|
|color constants text 145|188|||
|colors, maximum|number|of|189|
|command-line|parameters|133||
|comments|20|||
|built-in|assembler|256||
|common|types of integer|types|25|
|communication 141|devices|(COMI|and COM2)|
|Comp data comparing|type 28,|151,221||
|character|pointers|74||
|packed|strings 74|||
|pointers sets 74|74|||
|simple|types 73|||
|strings|74|||
|values compatibility assignment|of real types|153||
|parameter|type|||

$1 137 $L 279, *280, 283* $L filename *100, 157* $M 52,211 $N 29, 69, *130, 150,* 155, 257 *130,* $0 197 nonoverlay units and *202* $R 39, 224 $S52 $T 48,75 $X *20,31,43,54, 71*

|optimization|of code|245-251|
|---|---|---|
|complete|Boolean evaluation||
|compound|statement|syntax 84|
|Concatfunction|131||
|concatenation|71||
|conditional|statement|syntax 84|
|console device|(CON)||
|CONST constant|segment 279||
|address|expressions|59|
|declaration|part syntax|94|
|declarations|21||
|defined|11||
|expressions parameters|21||
|with an|initial value|11|
|constants|21||
|array-type|60||
|Dos unit|162||
|folding|245||
|Graph|unit 188||
|merging|246||
|numeric,|built-in assembler|263|
|object-type|62||
|pointer-type|63||
|procedural-type|64||
|record-type|62||
|set-type|63||
|simple-type|59||
|string,|built-in assembler|264|
|string-type|60||
|structured-type|60||
|typed|58||

*70*

*140*

*109*

*40* *110* compiler directives $N29 $P $A249 $B 71,246

*Index*

*104*

|constructors|37,|38, 222, 225|
|---|---|---|
|calling declaring defined|conventions||
|error|recovery||
|virtual|methods|and|
|Continue|procedure|87,|

*240* *103* *104* *106* *104* *130* control characters defined 15 embedding in strings 19 in Crt unit 143 string syntax diagram 20 control characters 19 Copy function 131 Cos function *130* CreateDir procedure 165 creating objects 38 Crt mode constants 145 unit 128, 142 control characters in 143 editing keys in 143 variables in 145 CS register 243 CSeg function 132 CSEG segment *280* current pointer 178 CX register 243

D data

|alignment|249||
|---|---|---|
|internal|formats||
|ports|231||
|segment|279,||
|maximum data formats|size|of 52|
|date and Dos unit|time procedures||
|WinDos|unit 163||
|DateTime|type 163||
|dead code|eliminated||
|debugging|overlays||
|Dec procedure|131||

*218-230*

*280*

*218-230*

*160*

declaration part, defined 11 declaring an object type 36 methods 37 Delay procedure 144 Delete procedure 131 DelLine procedure 144 descendants 34 of an object type 34 designators field 56 method 56 destructor syntax *105* destructors *104* calling conventions *240* declaring *103* defined *104* DetectGraph procedure 185 devices *140-141* communication (COMl and COM2) 141 console (CON) *140* DOS *140* drivers 146 handlers 243, 244 line printer (LPT1, LPT2, LPT3) 141 NUL 141 text file 141 DI register 243 diagrams, syntax 14 digit syntax diagram 15 digits, defined 15 direct memory access *230* port access 231 directives assembler, defined 259 built-in assembler 255, 274, 275 external *100* far 98 forward 99 inline *101* interrupt 99 list of Turbo Pascal 17 near 98 private public standard

*Language Guide*

how differ from virtual methods 38 overriding 38 object instances allocation and disposal of *104, 240* variables 43, 52, 56,211 disposing of 212

E $E compiler directive 28 editing keys in Crt unit 143 eliminate dead code *250* *240* Ellipse procedure 185 constructor passed as parameter *104, 114* embedding control characters in strings 19 disposU::tg of dynamic variables 212 empty set 42 div operator 69 EMS memory, overlay files and 192, 198 DMT (dynamic method table) emulating the 80x87 29 cache 228, 239 end-of-file character *140, 143* entry count 228 end-of-line character 15 domain of object type 34 entry code *240, 275* DOS enumerated device handling 244 constant's ordinality 27 devices *140* types 26, 219 environment *209* EnvCount function 161 error level 242 environment-handling functions exit code 241 Dos unit 161 operating system routines 159 WinDos unit 165 Dos unit 127, 159-163 EnvStr function 161 types 163 Eof function 135 DosError variable 163, 166 Eoln function 135 Dos Version function 162, 165 Erase procedure 135 double address-of (@@) operator 79 error checking Double data type 28, *151,220* dynamic object allocation *106* DrawPoly procedure 185 virtual method calls 224 driver constants 188 ErrorAddr variable 133, 242 drivers, graphics 175-177 errors DS register 241, 243 fatal, in OvrInit *200* DS segment *280* handling *180* DSeg function 132 reporting 241 DX register 235, 243 ES register 243 dynamic examples allocation procedures and functions 132 array type 31 method calls 239 avoiding ambiguity using subrange types 28 method index 38 character strings 19 method table 225 constant expressions 21, cache constructor entry count control characters in strings methods 38, enumerated type

*Index*

declarations *100* directive *100, 275* procedures and functions 157, 279 ExternProc *203* EXTRN directive *280*

F

*230* object-type declaration 34 record type 32 simple statements 8 subrange type 27

|$F compiler|directive|46, 99,|146, 198, 236|
|---|---|---|---|
|faAnyFile|constant|166||
|faArchive|constant|166||
|factor syntax|66|||
|faDirectory|constant|166||
|faHidden|constant|166||
|Fail procedure|107|||
|False predefined|constant|identifer|26|

syntax diagram 14 tokens *10* variables 11 variant part of a record 33 Exclude procedure 133 .EXE files 191 building *250* Exec procedure 161 exit code 241, 275 functions *240* procedures *240, 241* Exit procedure *130* ExitCode variable 133, 242 exiting a program 241 ExitProc variable 241 Exp function *130* exponents 219 expression syntax 66-68 expressions 65-79 absolute, built-in assembler *270* built-in assembler 262-274 classes *269-270* elements of 263-268 versus Pascal 262 constant 21 address 59 standard functions permitted in 22 defined 9 elements of, built-in assembler 263 order of evaluation 246 relocation, built-in assembler *270* types, built-in assembler *270* Extended data type 28, 151, *152,220* range arithmetic 152 range of *150* extended syntax *20,31,43* external (reserved word)

far ca11236 model 197 forcing use of 241 requirement 193 directive 98 faReadOnly constant 166 faSysFile constant 166 FAuxiliary constant 162 fAuxiliary constant 166 fa VolumeID constant 166 FCarry constant 162 fCarry constant 166 fcDirectory constant 166 fcExtension constant 166 fcFileName constant 166 fcWildcards constant 166 FExpand function 161 Fibonacci numbers 154 fields designators syntax 56 in record types 32 list (of records) 32 object 33 scope *103* record 55 figures, graphics 179 file *See also* files buffer *230* handles input and output 136-139 modes

*Language Guide*

*250* functions for 135 I/O 142 .OBJ 279 .OVR 191 procedures for 135 text 137 layout 229 typed 228 types of 228 untyped 139,228 FileSearch function 164 FileSize function 135 FileSplit function 164 source code of 173 fill pattern constants 188 FillChar procedure 133 FillEllipse procedure 185 FillPoly procedure 179, 185 FindFirst procedure 161, 164 finding the size of a given string 29 FindNext procedure 161, 164 fixed part of records 32 floating-point calculations, type Real and 151 code generation, switching *150* numbers 28, 149 numeric coprocessor (80x87) 29 parameters software

types Comp221 Double *220* Extended *220* Singe *220* FloodFill procedure 179, 185 flow-control procedures *130* Flush procedure 135 fmClosed constant 162, 166, 229 fmInOut constant 162, 166,229 fmInput constant 162, 166, 229 fmOutput constant 162, 166,229 font constants 188 fonts files 183 stroked 175, 178 for statement syntax 88 Force Far Calls option 198 formal parameter list syntax *108* parameters 76, 82, *107* forward declarations 99 directive 99 FOverflow constant 162 fOverflow constant 166 FParity constant 162 £Parity constant 166 Frac function *130* free list 215 FreeList variable 133 FreeMem procedure 132,212,213,215 FreeZero variable 133 fsDirectory constant 166 FSearch function 161 fsExtension constant 166 fsFileName constant 166 FSign constant 162 fSign constant 166 fsPathName constant 166 FSplit function 161 function calls 76, extended syntax and 76 syntax declarations *101-103* assembler

*Index*

*100*G headings *102*

|$G compiler|directive|257||
|---|---|---|---|
|GetArcCoords|procedure|185||
|GetArgCount|function|165||
|GetArgStr|function|165||
|GetAspectRatio|procedure|185||
|GetBkColor|function|185||
|GetCBreak|procedure|162, 165||
|GetColor|function|185||
|GetCurDir GetDate|function procedure|165||
|GetDefaultPalette|function|186,|189|
|GetDir|procedure|135||
|GetDriverName GetEnv|function function 161|186||
|GetEnvVar|function|165||
|GetFAttr|procedure|161, 164||
|GetFillPattern|procedure|186||
|GetFillSettings GetFTime|procedure procedure|186||
|GetGraphMode|function|186||
|GetImage GetIntVec|procedure procedure|175, 186||
|GetLineSettings|procedure|186||
|GetMaxColor|function|186||
|GetMaxMode|function|186||
|GetMaxX|function|186||
|GetMax|Y function|186||
|GetMem|procedure|56, 132,217||
|GetModeN|arne function|186||
|GetModeRange|procedure|186||
|GetPalette|procedure|186, 189||
|GetPaletteSize GetPixel|function function|186||
|GetTextSettings GetTime|procedure procedure|179,|186|
|GetVerify|procedure|162, 165||
|GetViewSettings|procedure||186|
|GetX function|186|||
|Get Y function|186|||
|goto statement|syntax|83||
|GotoXYprocedure||144||
|Graph3|unit 128|||
|Graph bit images colors|unit 128, 175, in 179|199||
|constants|188|||

results 235 returns, built-in assembler 275 syntax *101* functions 6, 97, *See also* procedures and functions address 132 arithmetic *130* calls 233 directory-handling 165 *160, 163* disk status Dos unit 161 WinDos unit 164 entry / exit code, built-in assembler 275 environment-handling Dos unit 161 WinDos unit 165 far 236 file-handling *160, 163* Dos unit 161 WinDos unit 164 graphics 185 *160, 164* heap-error *106* High 112 Low 112 miscellaneous Dos unit 162 WinDos unit 165 near 236 nested 236 ordinal 131 OvrGetRetry 195 parameters, built-in assembler 274 *180, 186* pointer 132 private 119 *160, 163* program example 6 SizeOf 112 stack frame for, built-in assembler 275 standard 129 and constant expressions 22 string 131 transfer *130* FZero constant 162 fZero constant

*Language Guide*

HeapError variable 133,217 HeapOrg variable 133,211,212 HeapPtr variable 133,211 hex digits 15 hexadecimal constants 18 numbers 19 Hi function 133, 245 Hidden constant 162 high bounds of index type of an array, finding 31 resolution graphics 176 High function 24,31, 112, 131 highest value in a range, finding 24 HighVideo procedure 144 host type 27

*180* figures and styles in 179 heap management routines 183 paging *180* procedures 185 sample program 181, 182 text in 178 types 189 variables 189 viewports in 179 GraphDefaults procedure 186 GraphDriver variable, IBM 8514 and 176 GraphErrorMsg function 186 GraphFreeMem procedure 183 GraphFreeMemPtr variable 189 GraphGetMem procedure 183 GraphGetMemPtr variable 189 graphics Close Graph 176 current pointer in 178 drivers 175 figures and styles 179 InitGraph in 176 mode constants 188 sample program 181, 182 using 175-189 GraphResult errors 188 GraphResult function *180, 186* grXXXX constants 188

H Halt procedure *130,241* handles, file 229 hardware, interrupts 243 heading, program 5 heap error function *106, 217* management allocating 211, 212, 215, 217 deallocating 212 fragmenting 211 free list 215 map *210* routines 183 manager 211-218 managing 211-218 HeapEnd variable

$1 compiler directive 137 I/O devices 146 error-checking 137 files 142 redirection 142 IBM 8514 175 driver support 176-177 GraphDriver variable and 176 InitGraph procedure and 176 modes 176 SetRGBPalette and 177 identifiers as labels 19 defined 17 examples 18 how identified in manuals 18 length of 17 qualified 17 restrictions on naming 17 scope of 23 if statement syntax 84 ImageSize function 186 immediate values, built-in assembler 269 implementation part of a unit 119, 236 implementing methods 37 in operator 73, Inc procedure Include procedure

*Index*

WinDos unit 164 Intr procedure *160, 164* IOResult function 135 *30* IP flag 243

|indexes in|arrays 31||
|---|---|---|
|indexing|character|pointers 171|
|indirect|unit references|120|
|infinite loop|See loop,|infinite|
|inheritance,|rules of|33|
|inherited|(reserved|word) 41|
|InitGraph|procedure|176, 186|
|initialization|part of|a unit 120|
|initialized|variables|58|
|in assembler|279||
|initializing inline|virtual methods|37,|
|directives|101,285||
|statements|284||
|InOutRes|variable|133|
|input and file 136-139|output||
|with Crt|unit 142-145||
|Input variable|133||
|Insert procedure|131||
|InsLine procedure||144|
|InstallUserDriver|function|186|
|InstallUserFont instances|function|186|
|dynamic|object 39||
|of an object|type|38|
|instantiating|objects|38|
|instruction|opcodes,|built-in assembler|
|Int function|130||
|Integer data|type 25,|218|
|integer types|25||
|interface|part of a unit|119, 236|
|internal data interrupt|formats|218-230|
|directive|243||
|directives|99||
|handlers|243||
|units|and 202||
|handling|routines|243|
|procedures,|writing|243|
|service|routines (ISRs)|243|
|support|procedures||
|Dos|unit 160||

ISRs (interrupt service routines) 243

J jump sizing, automatic, built-in assembler 258 justify text constants 188

K Keep procedure 161 keyboard status, testing 144 38 KeyPressed function 144

L $L compiler directive 279, *280, 283* $L filename compiler directive 1 ~O, *157* label declaration part syntax 93 syntax 19 labels built-in assembler 257 defined 19 language overview 5 LastMode variable 145 l~te binding 37 left brace special symbol 16 257 bracket special symbol 16 length character strings *20* identifiers 17 program lines *20* record *230* string-type value, finding 29 Length function 131,245 letters, defined 15 line input editing keys 143 printer devices (LPTl, LPT2, LPT3) 141 style constants 188 Line procedure 186 LineRel procedure lines, maxiumum length of LineTo procedure

*Language Guide*

*See* infinite loop low bounds of index type of an array, finding 31 Low function 24,31, 112, 131 lowest value in a range, finding 24 LowVideo procedure 144 LPT devices 141

M $M compiler directive 52, 211 machine code in program 284 Mark procedure 212 MaxAvail function 132 Mem array *230* MernA vail function 132 MemL array *230* memory allocation 199 map *210* model 281 references, built-in assembler 269 usage, Turbo Pascal and *209* Mem W array *230* method declarations *103-107* designator 56 syntax of *40* methods 33-42, *103-107* activating *40* assembly language 283 calling conventions 238 dynamic 239 declaring 37, *103* defined designators dynamic 38, 226, how differ from virtual methods

overriding 38 external 283 forward declaration 37 identifiers, qualified 37 implementation 37, *103* making them virtual 37 overriding inherited 37 parameters Self *103* defined 238 type compatibility *110* qualifying method identifiers 37 static 37 virtual 37 calling 238 error checking 224 initializing 38 miscellaneous procedures and functions Dos unit 162 WinDos unit 165 MkDir procedure 136 mod operator 69 Mode field 229 .MODEL directive 281 modular programming 118 Move procedure 133 MoveRel procedure 187 MoveTo procedure 187 MsDos procedure *160, 164*

N $N compiler directive 28, 29, 69, *130, 150, 155,* 257 Name field *230* near call 236 directive 98 nested procedures and functions 46, 236 network file access, read-only 139 New procedure 43, 56, 132,211,217 extended syntax 224 constructor passed as parameter *104, 114,* *240* used as function nil (reserved word) 43,56 NormVideo procedure NoSound procedure

*Index*

*70, 180*

|of identifier|in 36|
|---|---|
|objects||
|ancestor|34|
|constructors|222, 225|

NUL device 141 NULL character 167 null strings 19,29 null-terminated strings 31, 128, 167-174 declaring *103* defined 167 defined *104* NULL character 167 *106*

|error|recovery|
|---|---|
|virtual|methods|
|creating|38|

pointers and 169 and *104* standard procedures and 173 number constants 18 destructors *104* numbers declaring *103* counting 18 defined *104* hexadecimal 19

|domain|of 34||
|---|---|---|
|dynamic|||
|instances|39||
|allocation|and|disposal of|
|'method fields|table 225||
|designators|56||
|scope|36,||
|files in|$L directive|280|
|instantiating|38||
|internal|data format|222|
|methods,|scope 36||
|pointers|to 39||

integer 19 real 18 numeric *104, 240* constants, built-in assembler 263 coprocessor detecting 155 emulating, assembly language and 157 *103* evaluation stack 153 using 149-157

o $0

|compiler|directive|197|
|---|---|---|
|nonoverlay|units|and|
|.OBJ files object|279||
|ancestor|34||
|component|designators|56|
|descendant files 279|34||
|scope object-type|96||
|assignments|82||
|constants|62||
|object types|33-42,|See also objects|
|components|33||
|declaring|36||
|domain|34||
|fields|33||
|instances|38||
|methods|33||
|rules of scope|inheritance|33|
|in private|sections|36|
|in public|sections|36|

polymorphic *40, 110* *202* virtual method table 223 field 222 pointer initialization 225 methods call error checking 224 calling 238 Odd function 131, 245 Ofs function 132 open parameters

|108,|111|
|---|---|
|108,|113|
|3D, 108,|111|
||108|

array 32, how passed 235 string OpenString identifier 29, operands 65 built-in assembler 261 operators 65-75 @@ (double address-of) @ (address-of) 43, 56, address-of (@)

*Language Guide*

*70, 180* arithmetic 68 binary arithmetic 68 bitwise 69 Boolean *70* built-in assembler, defined 273 character pointer 71 div 69 logical 69 mod 69 not *70, 180* or *70, 180* precedence of 65, 69 built-in assembler 272 relational 73 set 72 *shl70* shr *70* string 71 structure member selector 268 types of 68 unary arithmetic 69 xor *70, 180* optimization of code 245-251 or operator *70, 180* Ord function 24, *130, 245* applied to an enumerated-type value 27 used to return a Char value 26 order of evaluation 248 ordering between two string-type values 29 ordinal procedures and functions 131 types 24-28 predefined 25 user-defined 25 ordinality defined 24 enumerated constant 27 finding enumerated type's value 27 returning 24 returning Char values 26 Output variable 133 OutText procedure 179, 187 OutTextXY procedure 179, 187 overlaid code, storing initialization code

programs designing *197-204* writing 192 routines, calling via procedure pointers *202* overlay manager, initializing 198 Overlay unit 128, 192 procedures and functions 195 overlays *191-204* assembly language routines and *203* BP register and *203* buffer 193 loading and freeing up 194 optimization algorithm 194 probationary area 195 size 211 cautions *202* debugging *202* defined 191 in .EXE files *205* installing a read function *204* loading into expanded memory 198 into memory 191 using *191-206* overriding dynamic methods 38 inherited methods 37 overview of Turbo Pascal language 5 .OVR files 191 OvrClearBuf procedure 196 OvrCodeList variable 133 OvrDebugPtr variable 134 OvrDosHandle variable 134 OvrEmsHandle variable 134 OvrFileMode variable 196 OvrGetBuf function 196 OvrGetRetry function 195, 196 OvrHeapEnd variable 134 OvrHeapOrg variable 134 OvrHeapPtr variable 134 OvrHeapSize variable 134 OvrInit procedure 196 OvrInitEMS procedure 196, 199 OvrLoadCount variable 196 OvrLoadList variable OvrReadBuf variable 196, OvrResult variable

*Index*

variable *204* pointers

|OvrSetBuf|procedure|196, 199,211|
|---|---|---|
|OvrSetRetry|procedure|195, 196|
|OvrTrapCount|variable|196|

assignment-compatibility of *40* comparing 74 to objects 39 types 43 pvalues 56 variables 56 $P compiler directive 111 polymorphism Pack procedure *130* parameter type compatibility *110* packed pointer assignment *40* reserved word *30* Port array 231 string type 31 PortW array 231 strings, comparing 74 Pos function 131 PackTime procedure *160, 163* pound (#) character 19 palette manipulation routines 177 precedence of operators 65, 69 ParamCount function 133 precision parameters *107-114* of real-type values 28 actual 82 rules of arithmetic 25 command-line 133 Pred function 24, 131,245 constant *109* predecessor of a value, returning 24 floating-point 234 PrefixSeg variable 134, *209* formal 82, *107* Printer unit 128, 141 open 111 printing from a program 141 array *108, 113* private string *108, 111* component sections 36 passing 83, 233-235 directive 17 Self *103* procedures and functions 119 defined 238 Private field *230* type compatibility *110* probationary area, overlay buffer 195 types of *108* PROC directive 281 untyped *110* procedural value *108, 234* types 44-46 variable *109* in expressions 78-79 *240*

|virtual|method||
|---|---|---|
|ParamStr|function 133||
|Pascal strings|168||
|passing parameters|233-235||
|by reference|233||
|by value|233||
|passing string|variables|of varying|
|PChar data Pi function|type 43||
|PieSlice procedure|187||
|pointer (A)|symbol 43,|56|
|pointer and|address functions|132|
|Pointer data|type 43,|221|
|pointer-type|constants.63||

type compatibility of 46 variable typecasts and 58 values 44 procedural-type constants 64 procedure call models 98 sizes *30* declaration syntax 97 declarations *97-101* *130* assembler *100* external *100*

|forward|99|
|---|---|
|inline||
|near and|far 98|
|headings|98|

*Language Guide*

program

|block|5|||
|---|---|---|---|
|comments|20|||
|defined|5|||
|heading|5, 117|||
|lines,|maximum|length|of 20|
|parameters|117|||
|syntax|117|||
|termination|241|||
|Program|Segment|Prefix (PSP)|209|
|Ptr function public|43, 56,|132, 245||
|component|sections|36||
|directive|17|||
|procedures|and|functions|119|
|PUBLIC|directives|279||
|PutImage|procedure|175,||
|PutPixel|procedure|||

*160* WinDos unit 163 directory-handling 165 Dispose, extended syntax 224, *240* constructor passed as parameter *104, 114* entry / exit code, built-in assembler 275 external 157 far 236 file-handling Dos unit 161 WinDos unit 164 flow control *130 180, 187* graphics 185 *180, 187* interrupt 99 supportQ Dos unit *160* WinDos unit 164 qualified

|identifiers|17|
|---|---|
|method||
|activating|a 41|
|designator|41|
|identifiers|37, 56, 75,|
|qualifier syntax|54|

miscellaneous Dos unit 162 WinDos unit 165 near 236 *103* nested 236 New extended syntax 224 constructor passed as parameter *104,* R *114,240*

|$R compiler|directive|39, 224||
|---|---|---|---|
|virtual Random|method checking function 133|224||
|Randomize|procedure|133||
|RandSeed range|variable|134||
|checking|172|||
|compile|time 249|||
|finding|higest value|in 24||
|finding|lowest value|in 24||
|of real-type|values|28||
|read-only|file access|139||
|Read procedure,|textfiles|136,|137|
|reading ReadKey|syntax diagrams function 144|14||
|Readln procedure|136|||
|ReadOnly|constant|162||

used as function 115 ordinal 131 OvrSetRetry 195 parameters, built-in assembler 274 pointers, calling overlaid routines *202* process-handling procedures 161 stack frame, built-in assembler 275 standard 129 string 131 procedures and functions *See also* procedures; functions nested 46 written in assembler 279 call model process-handling procedures

*Index*

*230* scope 95 types 32 record-type constant syntax 62 records 32, 55, 62, 222 fields 55 variant part 32 Rec5ize field *230* Rectangle procedure 187 recursive loop *See* recursive loop redeclaration of variables 51 redirection 142 reentrant code 243, 244 register-saving conventions 241 RegisterBGldriver function 176, 183, *187,202* RegisterBGIfont function 183, 187, *202* registers and inline statements 285 AX 235, 286 BP 241,243 overlays and *203* built-in assembler 265, 269 BX235,243 C5243 CX243 DI243 D5241,243 DX235,243 E5243 51243 5P241 55241 use, built-in assembler 256 using 235,241,243 Registers type 163 relational operators 73-75 Release procedure relocation expressions, built-in assembler RemoveDir procedure

Rename procedure 136 repeat statement syntax 87 repetitive statement syntax 87 reserved words 16 built-in assembler 261 defined 16 external 283 how identified in manuals 16 list of 16 Reset procedure 136, 147 RestoreCrtMode procedure 176, 187 RET instruction, built-in assembler 258 RETF instruction, built-in assembler 258 RETN instruction, built-in assembler 258 return character, defined 15 returning Char values 26 the ordinality of a value 24 the predecessor of a value 24 the successor of a value 24 Rewrite procedure 136, 147 right brace special symbol 16 bracket special symbol 1 ~ RmDir procedure 136 Round function *130, 245* round-off errors, minimizing 152 rules governing boolean variables 26 of inheritance 33 of scope 95-96 run-time errors 241, *See also* the *Programmer's Reference* library overview 127-128 RunError procedure *130*

5 $5 compiler directive 52 5aveIntXXXXX variables 134 scale factor syntax diagram 18 scope block 95 in object types 36 object record rules of 95, 95-96 type identifiers

*Language Guide*

*280* segments 279 SegXXXX variables 134 SelectorInc variable 134 Self parameter *40,* 41, *103, 240* defined 238 separating tokens 15 separators, defined 15 Seq function 132 set *See also* sets constructors 66 syntax 76 membership testing 75 operators 72 types 42, 221 set-type constants 63 SetActivePage procedure 187 SetAllPalette procedure 187, 189 SetAspectRatio procedure 187 SetBkColor procedure 187 SetCBreak procedure 162, 165 SetColor procedure 187 SetCurDir procedure 165 SetDate procedure *160, 163* SetFAttr procedure 161, 164 SetFillPattem procedure 179, 187 SetFillStyle procedure 179, 187 SetFTime procedure *160, 163* SetGraphBufSize procedure 183, 187 ,SetGraphMode procedure 176, 187 SetIntVec procedure *160, 164* SetLineStyle procedure 179, 187 SetPalette procedure 187 SetRGBPalette procedure 177, 187 IBM 8514 and 177 sets *See also* set comparing small

SetTextBuf procedure 136 SetTextJustify procedure 179, 187 SetTextStyle procedure 179, 187 SetTime procedure *160, 164* SetUserCharSize procedure 179, 187 SetVerify procedure 162, 165 SetViewPort procedure 187 SetVisualPage procedure 187 SetWriteMode procedure 187 Shift instructions faster than multiply or divide 249 shl operator *70* short-circuit Boolean evaluation *70, 246* Shortint data type 25 shr operator *70* SI register 243 signed number syntax diagram 18 significand 219 simple expression syntax 67 statement syntax 81 types 23-29 comparing 73 simple-type constants 59 Sin function 131 single character special symbols 16 Single data type 28, *151,220* size of a given string, finding 29 of overlay buffer 211 of structured types, maximum *30* of text file buffer *230* SizeOf function 112, 133 small sets 248 smart linking *250* software floating-point model 28 restrictions 29 interrupts 243 sound operations NoSound 144 Sound 144 Sound procedure 144 SP register space characters

*Index*

|SPtr function|132|||
|---|---|---|---|
|Sqr function|131|||
|Sqrt function|131|||
|SS register|241|||
|SSeg function stack 80x87153|132|||
|frame, built-in|assembler|use|of 275|
|overflow|52|||
|passing pointer|parameters|and the|233|
|segment|52,|||
|StackLimit standard|variable|134||
|directives|17|||
|functions|129|||
|procedure|and function|||
|defined|129|||
|procedure 46|or function|used|as a procedural|
|procedures|129|||
|units,|list of 127|||
|statement|part syntax|94||
|statements|81,|||
|assignment case 85|82|||
|compound|84|||
|conditional for 88 goto 83 84|84|||
|procedure|82|||
|repeat|87|||
|repetitive|87|||
|simple|81|||
|structured|83|||
|while with 90|87|||
|static methods storing|37|||
|null-terminated|strings|31||
|overlaid|code 211|||
|Str procedure|131|||

|StrCat function|168||
|---|---|---|
|StrComp function|168||
|StrCopy function|168||
|StrDispose|function|168|
|StrECopy|function 168||
|Str End function|168||
|StrIComp|function 168||
|string See|also strings||
|constants,|built-in|assembler|
|functions|131||
|literals, assigning||to PChar 169|
|operator|71||
|procedures type|131||
|default|size 29||
|ordering|between|two values|
|packed|31||
|typed,|constants||
|types 29,|221||
|variables|55||
|passing|30||
|strings See|also string||
|character|19||
|length|of 20||
|comparing|74||
|concatenating|71||
|coverting|168||
|embedding|control|characters|
|length|byte 221||
|maximum null 19,29|length|of 221|
|null-terminated|31,|128, 167-174|
|Pascal|168||
|Strings unit|128, 167||
|functions|in 167||
|using the|167||
|StrLCat function|168||
|StrLComp|function|168|
|StrLCopy|function|168|
|Str Len function|168||
|StrLIComp|function|168|
|StrLower|function 168||
|StrMove|function 168||
|StrNew function|168||
|stroked fonts|175, 178||
|StrPas function|168||
|StrPCopy|function|168|

*210* *210* 29

*60*

value

81~92in 19

if

*Language Guide*

TextBackground procedure 144 TextColor procedure 144 TextHeight function 187 TextMode procedure 144 TextRec record 229 *30, 30-42* type 163

|structured-type|constants|60|
|---|---|---|
|StrUpper|function 169||
|styles, graphics|179||
|subrange|type 27||
|subroutine|block 98||
|Succ function|24, 131,245||
|successor Swap function|of a value, 133, 245|returning 24|
|SwapVectors|procedure|161|
|symbols|15||
|built-in|assembler|265-268|
|invalid, list of|built-in assembler special 16|266|
|reserved,|built-in assembler|265|
|scope|access, built-in|assembler|
|special,|built-in assembler|265|
|syntax diagrams,|reading|14|
|SysFile constant|162||
|System unit floating-point|117, 127, routines|155|

TextWidth function 187 TFileRec type 166 tokens categories of 15 defined *10, 15* examples of *10* separating 15 transfer functions *130* trapping interrupts 243 TRegisters type 166 True predefined constant identifier 26 Trunc function *130, 245* Truncate procedure 136 TSearchRec type 166 268 TTextRec record 146 type 166 Turb03 unit 128 Turbo Assembler *280* *150* 80x87 emulation and 157 Turbo Pascal language overview 5-14 TURBO.TPL (run-time library) 127 T type *See also* types $T compiler directive 48, 75 declaration 23 tag field declaration part syntax 94 (of records) 32 defined *10* identifier 33 identifier 23 TDateTime type 166 type-checking, built in assembler *270* term syntax 67 typecasting integer-type values 25 terminating a program 241 typecasts Test8087 variable 134, 156 value 77 testing variable 57 keyboard status 144 typed set membership 75 constant text 178 defined 11 files 137 syntax 58 buffer *230* files 228 device drivers 146 TypeOf function devices types *23-50* text color constants arra y *30,* TextAttr variable

*Index*

simple 23-29 Single 24, 151 string 29,221 structured *30-42* subrange 27 Word 25 WordBool25,218

u unary

||||arithmetic|operators|69|
|---|---|---|---|---|---|
||220||operands unit syntax units 118-124 80x87 circular|65 118 coprocessor references|and 155 121|
|Extended|220||Crt 128,|142||
|Single|220||defined|13||
|Graph unit|189||Dos 127,|159-163||
|host 27|||Graph|128, 175||
|identical|46||Graph3128|||
|identity|46||heading|118||
|Integer 25,|218||identifiers|17||
|integer|||implementation||part 119|
|converting|through|typecasting|indirect|references|120|
|format|of 25||initialization|||
|range|of 25||code|201||
|LongBool|25, 218||part|120||
|Longint|25||interface|part 119||
|major classes|23||nonoverlay|202||
|object 33-42|||Overlay|128, 192||
|declaring|34||overlays|and 193||
|ordinal 24-28|||Printer|128, 141||
|characteristics|of|24|reasons|to use 13||
|predefined|25||scope|of 96||
|user-defined|25||standard,|list of|127|
|packed string|31||Strings|128, 167||
|PChar 43|||System|127||
|Pointer 43,221|||Turbo3128|||
|procedural|44, 44-46,|78|uses clause|117||
|Real 24|||version|number|121|
|real 28|||WinDos|127, 163-166||
|numbers|219||Unpack procedure||130|
|record 32, set 42,221|222||UnpackTime unsigned|procedure|160, 164|
|Shortint|25||constant|syntax 66||

integer syntax diagram

*Language Guide*

references 53 string 55 variant part of records 32 VGA emulated modes 176 *110* video memory 142 viewports 179

|UpCase|function 133|
|---|---|
|UserData|field 229|
|uses clause|13, 117|

virtual directive 37 methods 37 calling 238 v error checking 224

|Val procedure|131||
|---|---|---|
|value|||
|parameters|108,|234|
|typecast var|syntax 77||
|declaration|section|251|
|parameters|109,|234|
|and|the built-in|assembler|
|variable|See also variables||
|declaration|part syntax|94|
|declaration|syntax|51|
|defined|10||
|parameters reference|109||
|qualifiers|54||
|syntax|54||
|typecasts|57||
|and|procedural|types 58|
|variables|51-64||
|absolute|53||
|array|55||
|declarations|51||
|dynamic|43, 56, 211||
|disposing|of 212||
|FileMode|139||
|global|52||
|Graph|unit 189||
|in System|unit 133||
|initialized|133||
|initialized|in assembler|279|
|initializing local 52|58||
|parameters|234||
|pointer|56||
|record|55||

initializing 38 parameter *240*

table 223

field 222 pointer initialization 225 VolumeID constant 162

267 w

|WhereX function|145||
|---|---|---|
|Where Y function|145||
|while statement|syntax|87|
|WindMin|145||
|WinD os unit|127, 163-166||
|directory-handling 165||procedures|
|Window procedure windows|142,|144|
|with statement|syntax|90|
|word alignment,|automatic|249|
|Word data|type 25||
|WordBool|data type 25,|218|
|Write procedure|136||
|Writeln procedure|136||
|80x87 coprocessor|and|155|
|writing control|characters|143|

variable

and functions

x $X compiler directive *20,31,43,54, 71* xor operator *70, 180*

z zero-based character arrays 61, 169, 171

*Index*

*i*

#### B o R L A N D

|Corporate Headquarters|: 1800 Green|Hills Road, P. O. Box|660001, Scotts Valley|, CA 95067-0001|, (408) 438-8400|. Offices in : Australia|,|
|---|---|---|---|---|---|---|---|
|Belgium, Canada|, Denmark, France|, Hong Kong|, Italy, Japan, Korea|, Malay s ia, Netherlands,|New Zealand,|Singapore, Spain,||
|Sweden, Taiwan|, and United Kingdom|' Part 1 11 MN-TPL04-70|• BOR 4680|||||

, Germany
