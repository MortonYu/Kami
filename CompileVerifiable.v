Require Import Syntax StateMonad Properties All.

Set Implicit Arguments.
Set Asymmetric Patterns.

Section Compile.
  Variable ty: Kind -> Type.
  Variable regMapTy: Type.

  Notation NameVal := (string * {k: FullKind & Expr ty k})%type.
  
  Inductive RegMapExpr: Type :=
  | VarRegMap (v: regMapTy): RegMapExpr
  | UpdRegMap (r: string) (pred: Bool @# ty) (k: FullKind) (val: Expr ty k) (regMap: RegMapExpr): RegMapExpr
  | CompactRegMap (regMap: RegMapExpr): RegMapExpr.

  Inductive CompActionT: Kind -> Type :=
  | CompCall (f: string) (argRetK: Kind * Kind) (pred: Bool @# ty)
             (arg: fst argRetK @# ty)
             lret (cont: ty (snd argRetK) -> CompActionT lret): CompActionT lret
  | CompLetExpr k (e: Expr ty k) lret (cont: fullType ty k -> CompActionT lret): CompActionT lret
  | CompLetRegMap (rmap : RegMapExpr) lret (cont : regMapTy -> CompActionT lret): CompActionT lret
  | CompNondet k lret (Cont: fullType ty k -> CompActionT lret): CompActionT lret
  | CompSys (ls: list (SysT ty)) lret (cont: CompActionT lret): CompActionT lret
  | CompRead (r: string) (k: FullKind) (readMap: RegMapExpr) lret (cont: fullType ty k -> CompActionT lret): CompActionT lret
  | CompRet lret (e: lret @# ty) (newMap: RegMapExpr): CompActionT lret
  | CompLetFull k (a: CompActionT k) lret (cont: ty k -> regMapTy -> CompActionT lret): CompActionT lret.

  Axiom cheat: forall t, t.

  Section ReadMap.
    Variable readMap: regMapTy.
    Fixpoint compileAction k (a: ActionT ty k) (pred: Bool @# ty)
             (writeMap: RegMapExpr)
             {struct a}:
      CompActionT k :=
      match a in ActionT _ _ with
      | MCall meth k argExpr cont =>
        CompCall meth k pred argExpr (fun ret => @compileAction _ (cont ret) pred writeMap)
      | Return x =>
        CompRet x writeMap
      | LetExpr k' expr cont => CompLetExpr expr (fun ret => @compileAction _ (cont ret) pred writeMap)
      | ReadNondet k' cont => CompNondet k' (fun ret => @compileAction _ (cont ret) pred writeMap)
      | Sys ls cont => CompSys ls (compileAction cont pred writeMap)
      | ReadReg r k' cont =>
        @CompRead r k' (VarRegMap readMap) _ (fun v => @compileAction _ (cont v) pred writeMap)
      | WriteReg r k' expr cont =>
        CompLetRegMap (UpdRegMap r pred expr writeMap) (fun v => @compileAction _ cont pred (VarRegMap v))
      | LetAction k' a' cont =>
        CompLetFull (@compileAction k' a' pred writeMap)
                    (fun retval writeMap' => @compileAction k (cont retval) pred (VarRegMap writeMap'))
      | IfElse pred' k' aT aF cont =>
        CompLetFull (@compileAction k' aT (pred && pred')%kami_expr writeMap)
                    (fun valT writesT =>
                       CompLetFull (@compileAction k' aF (pred && !pred')%kami_expr (VarRegMap writesT))
                                   (fun valF writesF =>
                                      CompLetExpr (IF pred' then #valT else #valF)%kami_expr
                                                  (fun val => (@compileAction k (cont val) pred (VarRegMap writesF)))
                    ))
      end.

    Definition compileActions (acts: list (ActionT ty Void)) :=
      fold_left (fun acc a =>
                   CompLetFull acc (fun _ writeMap => compileAction a ($$ true)%kami_expr (CompactRegMap (VarRegMap writeMap)))) acts
                (CompRet ($$ WO)%kami_expr (VarRegMap readMap)).

    Definition compileRules (rules: list RuleT) :=
      compileActions (map (fun a => snd a ty) rules).
  End ReadMap.
End Compile.

Section Semantics.
  Local Notation UpdRegT := RegsT.
  Local Notation UpdRegsT := (list UpdRegT).

  Local Notation RegMapType := (RegsT * UpdRegsT)%type.

  Section PriorityUpds.
    Variable o: RegsT.
    Inductive PriorityUpds: UpdRegsT -> RegsT -> Prop :=
    | NoUpds: PriorityUpds nil o
    | ConsUpds (upds: UpdRegsT) (prevUpds: UpdRegsT) (prevRegs: RegsT)
               (prevCorrect: PriorityUpds prevUpds prevRegs)
               (u: UpdRegT)
               (curr: RegsT)
               (currRegsTCurr: getKindAttr o = getKindAttr curr)
               (Hcurr: forall s v, In (s, v) curr -> In (s, v) u \/ ((~ In s (map fst u)) /\ In (s, v) prevRegs))
               fullU
               (HFullU: fullU = u :: prevUpds):
        PriorityUpds fullU curr.

    Lemma prevPrevRegsTrue u prevUpds curr (currPriority: PriorityUpds (u :: prevUpds) curr):
      forall prev, PriorityUpds prevUpds prev -> getKindAttr o = getKindAttr prev.
    Proof.
      induction currPriority; simpl; auto; intros.
      inversion H; auto.
    Qed.
  End PriorityUpds.
    
  Inductive SemRegMapExpr: (RegMapExpr type RegMapType) -> RegMapType -> Prop :=
  | SemVarRegMap v:
      SemRegMapExpr (VarRegMap _ v) v
  | SemUpdRegMapTrue r (pred: Bool @# type) k val regMap
                     (PredTrue: evalExpr pred = true)
                     old upds
                     (HSemRegMap: SemRegMapExpr regMap (old, upds))
                     upds'
                     (HEqual : upds' = ((r, existT _ k (evalExpr val)) :: hd nil upds) :: tl upds):
      SemRegMapExpr (@UpdRegMap _ _ r pred k val regMap) (old, upds')
  | SemUpdRegMapFalse r (pred: Bool @# type) k val regMap
                      (PredTrue: evalExpr pred = false)
                      old upds
                      (HSemRegMap: SemRegMapExpr regMap (old, upds)):
      SemRegMapExpr (@UpdRegMap _ _ r pred k val regMap) (old, upds)
  | SemCompactRegMap old upds regMap (HSemRegMap: SemRegMapExpr regMap (old, upds)):
      SemRegMapExpr (@CompactRegMap _ _ regMap) (old, nil::upds).

  Inductive SemCompActionT: forall k, CompActionT type RegMapType k -> RegMapType ->  MethsT -> type k -> Prop :=
  | SemCompCallTrue (f: string) (argRetK: Kind * Kind) (pred: Bool @# type)
             (arg: fst argRetK @# type)
             lret (cont: type (snd argRetK) -> CompActionT _ _ lret)
             (ret: type (snd argRetK))
             regMap calls val
             (HSemCompActionT: SemCompActionT (cont ret) regMap calls val)
             (HPred : evalExpr pred = true):
      SemCompActionT (@CompCall _ _ f argRetK pred arg lret cont) regMap
                     ((f, existT _ argRetK (evalExpr arg, ret)) :: calls) val
  | SemCompCallFalse (f: string) (argRetK: Kind * Kind) (pred: Bool @# type)
             (arg: fst argRetK @# type)
             lret (cont: type (snd argRetK) -> CompActionT _ _ lret)
             (ret: type (snd argRetK))
             regMap calls val
             (HSemCompActionT: SemCompActionT (cont ret) regMap calls val)
             (HPred : evalExpr pred = false):
      SemCompActionT (@CompCall _ _ f argRetK pred arg lret cont) regMap calls val
  | SemCompLetExpr k e lret cont
                   regMap calls val
                   (HSemCompActionT: SemCompActionT (cont (evalExpr e)) regMap calls val):
      SemCompActionT (@CompLetExpr _ _ k e lret cont) regMap calls val
  | SemCompLetRegMap lret cont
                     regMapExpr calls val regMap regMap'
                     (HNoDupUpds : NoDup (map fst (hd nil (snd regMap))))
                     (HSemRegMap : SemRegMapExpr regMapExpr regMap)
                     (HSemCompActionT: SemCompActionT (cont regMap) regMap' calls val):
      SemCompActionT (@CompLetRegMap _ _ regMapExpr lret cont) regMap' calls val
  | SemCompNondet k lret cont
                  ret regMap calls val
                  (HSemCompActionT: SemCompActionT (cont ret) regMap calls val):
      SemCompActionT (@CompNondet _ _ k lret cont) regMap calls val
  | SemCompSys ls lret cont
               regMap calls val
               (HSemCompActionT: SemCompActionT cont regMap calls val):
      SemCompActionT (@CompSys _ _ ls lret cont) regMap calls val
  | SemCompRead r k readMap lret cont
                regMap calls val regVal
                updatedRegs readMapValOld readMapValUpds
                (HReadMap: SemRegMapExpr readMap (readMapValOld, readMapValUpds))
                (HUpdatedRegs: PriorityUpds readMapValOld readMapValUpds updatedRegs)
                (HIn: In (r, (existT _ k regVal)) updatedRegs)
                (HSemCompActionT: SemCompActionT (cont regVal) regMap calls val):
      SemCompActionT (@CompRead _ _ r k readMap lret cont) regMap calls val
  | SemCompRet lret e regMap regMapVal
               (HRegMap: SemRegMapExpr regMap regMapVal):
      SemCompActionT (@CompRet _ _ lret e regMap) regMapVal nil (evalExpr e)
  | SemCompLetFull k a lret cont
                   regMap_a calls_a val_a
                   (HSemCompActionT_a: SemCompActionT a regMap_a calls_a val_a)
                   regMap_cont calls_cont val_cont
                   (HSemCompActionT_cont: SemCompActionT (cont val_a regMap_a) regMap_cont calls_cont val_cont):
      SemCompActionT (@CompLetFull _ _ k a lret cont) regMap_cont (calls_cont ++ calls_a) val_cont.
End Semantics.

Lemma getKindAttr_fst {A B : Type} {P : B -> Type}  {Q : B -> Type} (l1 : list (A * {x : B & P x})):
  forall  (l2 : list (A * {x : B & Q x})),
    getKindAttr l1 = getKindAttr l2 ->
    (map fst l1) = (map fst l2).
Proof.
  induction l1, l2; intros; auto; simpl in *; inv H.
  erewrite IHl1; eauto.
Qed.

Lemma SemRegExprVals expr :
  forall o1 o2,
  SemRegMapExpr expr o1 ->
  SemRegMapExpr expr o2 ->
  o1 = o2.
Proof.
  induction expr; intros; inv H; inv H0; EqDep_subst; auto;
    try congruence; specialize (IHexpr _ _ HSemRegMap HSemRegMap0); inv IHexpr; auto.
Qed.

(*
Lemma NoDup_RegMapExpr (rexpr : RegMapExpr type (RegsT * (list RegsT))):
  forall old new u,
    SemRegMapExpr rexpr (old, u::new) ->
    NoDup (map fst u).
Proof.
  induction rexpr; intros.
  - inv H; simpl in *; eapply HDisjKeys; left; reflexivity.
  - inv H; EqDep_subst; simpl in *.
    + induction upds; simpl in *.
      * inv HEqual; simpl.
        constructor;[intro; inv H|constructor].
      * inv HEqual; simpl in *.
        specialize (IHrexpr _ _ _ HSemRegMap).
        constructor; auto.
        rewrite in_map_iff; intro; dest; destruct x; subst; simpl in *.
        apply (HDisjUpds s0); assumption.
    + eapply IHrexpr; eauto.
  - inv H; EqDep_subst.
    constructor.
Qed.

Lemma NoDup_RegMapExprs rexpr:
  forall old new,
    SemRegMapExpr rexpr (old, new) ->
    (forall u, In u new -> NoDup (map fst u)).
Proof.
  induction rexpr; intros; simpl in *.
  - inv H; simpl in *; eauto.
  - inv H; EqDep_subst; simpl in *.
    + destruct upds; destruct H0; subst; simpl in *.
      * repeat constructor; auto.
      * contradiction.
      * constructor.
        -- rewrite in_map_iff; intro; dest; destruct x; subst; simpl in *.
           apply (HDisjUpds s0); assumption.
        -- eapply NoDup_RegMapExpr; eauto.
      * eapply IHrexpr; eauto.
        right; assumption.
    + eauto.
  - inv H; simpl in *; destruct H0; subst; simpl; eauto.
    constructor.
Qed.
 *)
(*
Lemma NoDup_UpdKeys (k : Kind) (a : ActionT type k) :
  forall o calls retl rexpr old u upds (bexpr : Bool @# type)
         (NoDups : (forall u, In u upds -> NoDup (map fst u))),
    SemCompActionT (compileAction (o, nil) a bexpr rexpr) (old, u::upds) calls retl ->
    NoDup (map fst u).
Proof.
  induction a; intros.
  - inv H0; EqDep_subst.
    + eapply H; eauto.
    + eapply H; eauto.
  - inv H0; EqDep_subst.
    eapply H; eauto.
  - inv H0; EqDep_subst.
    eapply H; eauto.
  - inv H0; EqDep_subst.
    eapply H; eauto.
  - inv H0; EqDep_subst.
    eapply H; eauto.
  - inv H; simpl in *; auto.
  - inv H0; EqDep_subst.
    inv HSemCompActionT_cont; EqDep_subst.
    inv HSemCompActionT_cont0; EqDep_subst.
    destruct (evalExpr e); simpl in *; EqDep_subst.
    + eapply H; eauto.
    + eapply H; eauto.
  - inv H; EqDep_subst; eapply IHa; eauto.
  - inv H; EqDep_subst.
    admit.
Admitted.
*)
(*
Lemma EquivWrites (k : Kind) (a : ActionT type k):
  forall o calls retl expr1 expr2 v v' (bexpr : Bool @# type),
    SemRegMapExpr expr1 v ->
    SemRegMapExpr expr2 v ->
    SemCompActionT (compileAction o a bexpr expr1) v' calls retl ->
    SemCompActionT (compileAction o a bexpr expr2) v' calls retl.
Proof.
  induction a; intros; simpl in *; eauto.
  - inv H2; EqDep_subst; econstructor; eauto.
  - inv H2; EqDep_subst; econstructor; eauto.
  - inv H2; EqDep_subst; econstructor; eauto.
  - inv H2; EqDep_subst; econstructor; eauto.
  - inv H2; EqDep_subst; econstructor; eauto.
  - remember (evalExpr bexpr) as P1.
    destruct P1, v.
    + eapply IHa in H1.
      * apply H1.
      * econstructor; eauto.
      * econstructor; eauto.
    + eapply IHa in H1; try econstructor 3; eauto.
  - inv H2; EqDep_subst.
    inv HSemCompActionT_cont; EqDep_subst.
    econstructor; eauto.
    econstructor; eauto.
  - inv H1; EqDep_subst; econstructor; eauto.
  - inv H1; EqDep_subst.
    econstructor.
    destruct v, v'.
    pose proof (@SemRegExprVals _ _ _ _ _ H HRegMap); dest; subst; auto.
Qed.
*)    

Lemma UpdRegs_same_nil o :
  UpdRegs (nil::nil) o o.
Proof.
  unfold UpdRegs.
  repeat split; auto.
  intros.
  right; unfold not; split; intros; dest; auto.
  destruct H0; subst; auto.
Qed.


(*  induction a; subst; intros; simpl in *.
  - inv H0; EqDep_subst.
    + specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT newRegs eq_refl); dest.
      exists x.
      econstructor; eauto.
    + discriminate.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT newRegs eq_refl); dest.
    exists x.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (IHa _ _ _ HSem _ _ _ _ HSemCompActionT_a newRegs); dest.
    admit.
(*    assert (SemRegMapExpr (VarRegMap type regMap_a) (old, (newRegs ++ hd nil upds) :: tl upds)) as HSem0.
    {
      econstructor 1.
      rewrite H0 in *; constructor.
      eapply (NoDup_UpdKeys _ _ _ _ HSemCompActionT_a).
    }
    specialize (H _ _ _ _ HSem0 _ _ _ _ HSemCompActionT_cont); dest.
    exists (x1++x), (x0++x2); split.
    + simpl in *.
      rewrite <- app_assoc; assumption.
    + econstructor; eauto.
      * rewrite H in HSemCompActionT_cont.
        specialize (NoDup_UpdKeys _ _ _ _ HSemCompActionT_cont) as P0.
        intro.
        destruct (In_dec string_dec k0 (map fst x)); auto.
        right; intro.
        simpl in P0.
        
        specialize (P0 (x1 ++ x ++ hd nil upds) (or_introl eq_refl)).
        -- repeat rewrite map_app in P0.
           apply in_split in i; apply in_split in H3; dest.
           rewrite H4, H3 in P0.
           assert ((x3 ++ k0 :: x4) ++ (x5 ++ k0 :: x6) = ((x3 ++ k0::x4)++ x5) ++ (k0::x6)).
           { rewrite app_assoc; reflexivity. }
           rewrite app_assoc, H5 in P0.
           rewrite <- app_assoc in P0.
           apply NoDup_remove_2 in P0; apply P0.
           repeat rewrite in_app_iff; left; left;right;simpl; left; reflexivity.
 *)
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT newRegs eq_refl); dest; subst.
    exists x.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    inv HReadMap; inv HUpdatedRegs; simpl in *.
    specialize (H regVal _ _ _ HReadMap o calls retl (o, readMapValUpds)).
    exists x, ((r, existT _ k regVal)::x0); split; auto.
    econstructor; eauto.
    inv HReadMap.
    inv HUpdatedRegs; auto.
    discriminate.
  - admit.
  - admit.
  - admit.
  - admit.
  - admit.
  - subst.
    inv H; EqDep_subst; exists nil.
    constructor; eauto.
    destruct (SemRegExprVals HSem HRegMap); subst.
    destruct upds; simpl in *.
    inv H0.
    inv H0; subst.
    clear - H2.
    assert (nil++r = r); auto.
    rewrite <- H in H2 at 1.
    apply app_inv_tail in H2.
    auto.
    
(*    exists newRegs readRegs,
      upds' = (old, (newRegs ++ (hd nil upds))::(tl upds)) /\
      SemAction o a readRegs newRegs calls retl. *) *)

Lemma NoDup_app_split {A : Type} (l l' : list A) :
  NoDup (l++l') ->
  forall a,
    In a l ->
    ~ In a l'.
Proof.
  induction l'; repeat intro;[inv H1|].
  specialize (NoDup_remove _ _ _ H) as P0; dest.
  inv H1; apply H3; rewrite in_app_iff; auto.
  exfalso; eapply IHl'; eauto.
Qed.

(*
Lemma foo (lretT : Kind) (k : FullKind) a :
  forall writeMap old upds (HSem : SemRegMapExpr writeMap (old, upds)) o calls (retl : type lretT) upds' r (e : Expr type k),
    SemCompActionT (compileAction (o, nil) a (Const type true) (UpdRegMap r (Const type true) e writeMap)) upds' calls retl ->
    key_not_In r (hd nil upds).
Proof.
  induction a; intros; try (inv H0; EqDep_subst; eauto).
  -
 *)
(*

Lemma EquivActions k a:
  forall
    writeMap old upds
    (HSem: SemRegMapExpr writeMap (old, upds)) (NoDupUpds : forall u, In u upds -> NoDup (map fst u)),
  forall o calls retl upds',
    @SemCompActionT k (compileAction (o, nil) a (Const type true) writeMap) upds' calls retl ->
    (forall u, In u (snd upds') -> NoDup (map fst u)) /\
    exists newRegs readRegs,
      upds' = (old, match newRegs with
                    |nil => upds
                    |_ :: _ => (newRegs ++ hd nil upds) :: tl upds
                    end) /\
      SemAction o a readRegs newRegs calls retl.
Proof.
  induction a; subst; intros; simpl in *.
  - inv H0; EqDep_subst;[|discriminate].
    specialize (H _ _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT); dest; split; auto.
    exists x, x0; split; auto.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT); dest; split; auto.
    exists x, x0; split; auto.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (IHa _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT_a); dest.
    assert (SemRegMapExpr (VarRegMap type regMap_a) (old, snd regMap_a)) as HSem0.
    { rewrite H1; constructor. }
    specialize (H _ _ _ _ HSem0 H0 _ _ _ _ HSemCompActionT_cont); dest.
    split; auto.
    exists (x1++x), (x2++x0); split.
    + rewrite H1 in *; destruct x; simpl in *; auto.
      * rewrite app_nil_r; assumption.
      * destruct x1; simpl in *; auto.
        rewrite <-app_assoc, app_comm_cons; auto.
    + econstructor; eauto.
      rewrite H3, H1 in H; simpl in *.
      clear - H.
      destruct x, x1; eauto using DisjKey_nil_r, DisjKey_nil_l; simpl in *.
      specialize (H _ (or_introl _ eq_refl)); simpl in *.
      rewrite map_app, app_comm_cons in H.
      intro.
      destruct (In_dec string_dec k (map fst (p0::x1))); auto.
      right; intro.
      destruct (NoDup_app_Disj string_dec _ _ H k); auto.
      apply H1; simpl in *; rewrite map_app, in_app_iff.
      clear - H0; firstorder fail.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT); dest; split; auto.
    exists x, x0; split; auto.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT); dest; split; auto.
    exists x, ((r, existT _ k regVal) :: x0).
    split; auto.
    econstructor; eauto.
    inv HReadMap; inv HUpdatedRegs; auto.
    discriminate.
  - inv H; EqDep_subst.
    inv HSemRegMap; EqDep_subst; simpl in *; [|discriminate].
    assert (SemRegMapExpr (VarRegMap type (old0, ((r, existT (fullType type) k (evalExpr e)) :: hd nil upds0) :: tl upds0))
                          (old0, ((r, existT (fullType type) k (evalExpr e)) :: hd nil upds0) :: tl upds0)).
    { constructor. }
    specialize (SemRegExprVals HSem HSemRegMap0) as P0; inv P0.
    assert (forall u, In u (((r, existT (fullType type) k (evalExpr e)) :: hd nil upds0) :: tl upds0) -> NoDup (map fst u)).
    { intros; simpl in *.
      destruct H0; subst; simpl in *; auto.
      eapply NoDupUpds.
      destruct upds0; simpl in *; auto.
    }
    specialize (IHa _ _ _ H H0 _ _ _ _ HSemCompActionT); dest; split; auto.
    exists ((r, existT (fullType type) k (evalExpr e))::x), x0; split.
    + destruct x; simpl in *; auto.
      repeat rewrite app_comm_cons.
      repeat rewrite <-app_assoc; simpl.
      admit.
    + econstructor; eauto.
      assumption.
    + admit.
  -
    SearchPattern (_ -> (_::nil)++_ = _::_).
      
    specialize (IHa _ _ _ HSem NoDupUpds _ _ _ _ HSemCompActionT).
    split; auto.
    + intros.
      destruct H; subst; simpl; auto.
      eapply NoDupUpds.
      destruct upds1;simpl in *; auto.
    + 
    
        
      
      
      
      
      
      rewrite 
        
      
    + econstructor; eauto.
    admit.
  - admit.
  - admit.
  - admit.
  - admit.
  -
  induction a; subst; intros; simpl in *.
  - inv H0; EqDep_subst.
    + specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT); dest.
      exists x, x0, x1; repeat split; auto.
      econstructor; eauto.
    + discriminate.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT); dest.
    exists x, x0, x1; repeat split; auto.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (IHa _ _ _ HSem _ _ _ _ HSemCompActionT_a); dest.
    assert (SemRegMapExpr (VarRegMap type regMap_a) (old, snd regMap_a)) as HSem0.
    {
      rewrite H0 in *; constructor; auto.
      intros.
      eapply (NoDup_UpdKeys _ _ _ _ HSemCompActionT_a); simpl in *; auto.
    }
    specialize (H _ _ _ _ HSem0 _ _ _ _ HSemCompActionT_cont); dest.
    exists (x2++x), (x0++x3),(x1++x4); split.
    + rewrite H0 in H; simpl in *.
      destruct x. rewrite app_nil_r. assumption.
      destruct x2. simpl in *. assumption.
      simpl in *. rewrite <- app_assoc. rewrite <- app_comm_cons. assumption.
    + repeat split.
      rewrite Permutation.Permutation_app_comm. apply Permutation.Permutation_app; auto.
      econstructor; eauto.
      intro.
      destruct (In_dec string_dec k0 (map fst x0));[|auto].
      right; intro.
      destruct upds'.
      specialize (NoDup_UpdKeys _ _ _ _ HSemCompActionT_cont) as P0.
      rewrite H0 in H.
      inv H.
      destruct x.
      apply Permutation.Permutation_nil in H1.
      rewrite H1 in i.
      inversion i.
      destruct x2.
      apply Permutation.Permutation_nil in H3.
      rewrite H3 in H5.
      inversion H5.
      simpl in *.
      specialize (P0 _ (or_introl eq_refl)).
      rewrite <- H3 in H5.
      rewrite <- H1 in i.
      simpl in *.
      destruct i, H5.
      subst.
      inv P0.
      apply H6.
      rewrite map_app. simpl.
      rewrite H0.
      rewrite in_app_iff.
      right.
      left.
      reflexivity.
      inv P0.
      rewrite map_app in H8; simpl in H8.
      apply NoDup_remove_2 in H8.
      apply H8.
      rewrite in_app_iff.
      left.
      assumption.
      subst.
      inv P0.
      apply H6.
      rewrite map_app.
      simpl.
      rewrite in_app_iff.
      right.
      right.
      rewrite map_app.
      rewrite in_app_iff.
      left.
      assumption.
      inv P0.
      rewrite map_app in H8.
      specialize (NoDup_app_Disj string_dec _ _ H8 k0) as P1.
      destruct P1; [contradiction|].
      apply H5.
      right.
      rewrite map_app.
      rewrite in_app_iff.
      left.
      assumption.
(*      
                 
      inv P0.
      destruct x; simpl in *; auto.
      destruct x2; simpl in *; [rewrite app_nil_r|]; auto.
      rewrite <- app_assoc, <-app_comm_cons; assumption.
    + econstructor; eauto.
      * rewrite H in HSemCompActionT_cont.
        specialize (NoDup_UpdKeys _ _ _ _ HSemCompActionT_cont) as P0.
        intro.
        destruct (In_dec string_dec k0 (map fst x)) ; auto.
        right; intro.
        simpl in P0.
        destruct x1;[contradiction|].
        rewrite H0 in P0.
        destruct x;[contradiction|simpl in *].
        specialize (P0 ((p::x1) ++ (p0::x) ++ hd nil upds) (or_introl eq_refl)).
        repeat (simpl in *; rewrite map_app in P0).
        destruct i, H3; subst.
        -- inv P0; apply H4.
           rewrite H3; rewrite in_app_iff.
           right; left; reflexivity.
        -- inv P0.
           apply (NoDup_remove_2 _ _ _ H5); rewrite in_app_iff; left; auto.
        -- inv P0.
           apply H3; repeat (rewrite in_app_iff; simpl).
           right; right; left; auto.
        -- rewrite app_comm_cons in P0.
           apply (NoDup_app_split _ _ P0 _ (in_cons _ _ _ H3)).
           simpl; rewrite in_app_iff; right; left; assumption.
*)
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT); dest; subst.
    exists x, x0, x1; repeat split; auto.
    econstructor; eauto.
  - inv H0; EqDep_subst.
    specialize (H _ _ _ _ HSem _ _ _ _ HSemCompActionT); dest; subst.
    exists x, x0, ((r, existT _ k regVal)::x1); repeat split; auto.
    econstructor; eauto.
    inv HReadMap.
    inv HUpdatedRegs; auto.
    discriminate.
  - assert (SemRegMapExpr (UpdRegMap r (Const type true) e writeMap) (old, (((r, existT _ k (evalExpr e)) :: hd nil upds) :: tl upds))) as P0.
    {
      econstructor; eauto.
      
  - admit.
  - inv H; EqDep_subst.
    specialize (IHa _ _ _ HSem _ _ _ _ HSemCompActionT); dest; subst.
    exists x, x0, x1; repeat split; auto.
    constructor; assumption.
  - exists nil, nil, nil; simpl in *.
    inv H; EqDep_subst.
    repeat split; [ | |constructor]; auto.
    destruct upds'.
    destruct (SemRegExprVals HSem HRegMap); subst.
    destruct l; simpl in *; auto.
Admitted.
 *)