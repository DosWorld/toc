MODULE Ptrlib;
TYPE
  Item* = RECORD
    a*: INTEGER
  END;
  ItemArr* = POINTER TO ARRAY 10 OF Item;

PROCEDURE Fill*(VAR arr: ItemArr);
BEGIN
  NEW(arr);
  arr[0].a := 42
END Fill;
END Ptrlib.
