! $Id: planet.f90,v 1.42 2006-05-23 15:03:52 wlyra Exp $
!
!  This modules contains the routines for accretion disk and planet
!  building simulations. 
!
!** AUTOMATIC CPARAM.INC GENERATION ****************************
! Declare (for generation of cparam.inc) the number of f array
! variables and auxiliary variables added by this module
!
! CPARAM logical, parameter :: lplanet = .true.
!
! MVAR CONTRIBUTION 0
! MAUX CONTRIBUTION 0
!
! PENCILS PROVIDED uu_kep
!
!***************************************************************
!
! This module takes care of (mostly) everything related to the 
! planet module
!
module Planet
!  
  use Cdata
  use Cparam
  use Messages
!  
  implicit none
!  
  include 'planet.h' 
!  
! initialize variables needed for the planet module
!
!
! start and run parameters
!
!
! things needed for companion
!
  real :: gc=0.          !location and mass
  real :: b=0.           !peak radius for potential
  integer :: nc=2        !exponent of smoothed potential 
  integer :: n_periods=5 !periods for ramping
  logical :: lramp=.false.
  logical :: lwavedamp=.false.,llocal_iso=.false.
  logical :: lsmoothlocal=.false.,lcs2_global=.false.
  logical :: lmigrate=.false.,lnorm=.false.
  real :: Gvalue=1. !gravity constant in same unit as density
  logical :: ldnolog=.true.,lcs2_thick=.false.
  logical :: lcalc_turb=.false.
  integer :: nr=10
!
  namelist /planet_init_pars/ gc,nc,b,lsmoothlocal,&
       lcs2_global,llocal_iso,lcs2_thick
!
  namelist /planet_run_pars/ gc,nc,b,lramp, &
       lwavedamp,llocal_iso,lsmoothlocal,lcs2_global, &
       lmigrate,lnorm,Gvalue,n_periods,ldnolog,lcs2_thick,nr,&
       lcalc_turb
! 
  integer :: idiag_torqint=0,idiag_torqext=0
  integer :: idiag_totenergy=0,idiag_totangmom=0
  integer :: idiag_totmass2=0
!
  contains
!
!***********************************************************************
    subroutine register_planet()
!
!  06-nov-05/wlad: coded
!
      use Mpicomm, only: stop_it
!
      logical, save :: first=.true.
!
      if (.not. first) call stop_it('register_planet called twice')
      first = .false.
!
      if ((ip<=8) .and. lroot) then
        print*, 'register_planet: ENTER'
      endif
!
!  identify version number
!
      if (lroot) call cvs_id( &
           "$Id: planet.f90,v 1.42 2006-05-23 15:03:52 wlyra Exp $")
!
      if (nvar > mvar) then
        if (lroot) write(0,*) 'nvar = ', nvar, ', mvar = ', mvar
        call stop_it('register_planet: nvar > mvar')
      endif
!
    endsubroutine register_planet
!***********************************************************************
    subroutine initialize_planet(f,lstarting)
!
!  Perform any post-parameter-read initialization i.e. calculate derived
!  parameters.
!
!  08-nov-05/wlad: coded
!  02-feb-06/wlad: sound speed set as global in start time
!
!will need to add itorque as f-variable
!
      use Mpicomm, only : stop_it
!
      real, dimension (mx,my,mz,mvar+maux) :: f
      logical :: lstarting
!
      if (lroot) print*, 'initialize_planet'
!
      if (lcs2_global) then
         if (llocal_iso) then
            do n=n1,n2
               do m=m1,m2
                  call set_soundspeed
               enddo
            enddo
         else
            print*,'planet : not isothermal, but sound speed is set'
            print*,'as global variable. Better stop and check'
            call stop_it('')
         endif
      endif
!
    endsubroutine initialize_planet
!***********************************************************************
    subroutine pencil_criteria_planet()
! 
!  All pencils that the Planet module depends on are specified here.
! 
!  06-nov-05/wlad: coded
!
      lpenc_requested(i_lnrho)=.true.
      lpenc_requested(i_rho)=.true.
      lpenc_requested(i_uu)=.true.
      lpenc_requested(i_u2)=.true.
      lpenc_requested(i_bb)=.true.
!
    endsubroutine pencil_criteria_planet
!***********************************************************************
    subroutine calc_pencils_planet(f,p,g0,r0_pot)
!
! calculate keplerian velocity as a pencil, so I don't
! have to recalculate it on other routines from f,g0 and r0_pot
!
! 28-mar-06/wlad : coded 
!
      real, dimension(mx,my,mz,mvar+maux) :: f
      real, dimension(nx) :: rc_mn
      type (pencil_case) :: p
      real :: g0,r0_pot
!
      intent(in) :: f
      intent(inout) :: p
!   
      if (lpencil(i_uu_kep)) then
         rc_mn = sqrt(x(l1:l2)**2 + y(m)**2)
         p%uu_kep = rc_mn*sqrt(g0*(rc_mn**2+r0_pot**2)**(-1.5))
      endif
!
    endsubroutine calc_pencils_planet
!***********************************************************************
    subroutine read_planet_init_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
!            
      if (present(iostat)) then
        read(unit,NML=planet_init_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=planet_init_pars,ERR=99)
      endif
!
99    return
    endsubroutine read_planet_init_pars
!***********************************************************************
    subroutine write_planet_init_pars(unit)
      integer, intent(in) :: unit
!
      write(unit,NML=planet_init_pars)
!                                                                         
    endsubroutine write_planet_init_pars
!***********************************************************************
    subroutine read_planet_run_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
!
      if (present(iostat)) then
        read(unit,NML=planet_run_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=planet_run_pars,ERR=99)
      endif
!
99    return
    endsubroutine read_planet_run_pars
!***********************************************************************
    subroutine write_planet_run_pars(unit)
      integer, intent(in) :: unit
!
      write(unit,NML=planet_run_pars)
!
    endsubroutine write_planet_run_pars
!***********************************************************************
    subroutine gravity_companion(f,df,fp,dfp,g0,r0_pot,n_pot,p)
!
!  calculate the gravity of a companion offcentered by (Rx,Ry,Rz)
!
!  12-aug-05/wlad       : coded
!  08-nov-05/wlad       : moved here (previously in Gravity Module)
!  21-nov-05/wlad+anders: changed orbital elements approach to
!                         particles' positions and velocities   
!
      use Sub
      use Global
      use Particles_Cdata
      use Mpicomm
!     
      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (mx,my,mz,mvar) :: df
      real, dimension (mpar_loc,mpvar) :: fp,dfp 
      real, dimension (nx,3) :: ggc,ggs
      real, dimension (nx) :: g_companion,rrc,rrs,g_star
      real :: Omega_inertial,ax,ay,az,gtc
      real :: axs,ays,azs,g0,gp,gs,r0_pot,mdot,m2dot
      integer :: n_pot
      logical :: lheader,lfirstcall=.true.
      type (pencil_case) :: p
!
!  Position of the particles
!  1 is planet, 2 is star
!
      ax = fp(1,ixp) ; axs = fp(2,ixp) 
      ay = fp(1,iyp) ; ays = fp(2,iyp) 
      az = fp(1,izp) ; azs = fp(2,izp) 
!
      lheader = lfirstcall .and. headtt .and. lroot
!
      if (headtt) print*,&
           'gravity_companion: Adding gravity of companion located at x,y,z=',&
           ax,ay,az
      if (lheader) print*,&
           'gravity_companion: Mass ratio of secondary-to-primary = ',gc/g0
!
      if (lheader.and.(Omega.eq.0)) print*,'gravity_companion: inertial frame'
!
      if (Omega/=0) &
           call stop_it('gravity_companion: Corotation not implemented')
!
!  Ramp up the mass of the planet for 5 periods
!
      ggc=0.
      if (gc.ne.0) then 
         call get_ramped_mass(gp,gs,g0,mdot,m2dot)
!
!  Planet's gravity field
!
         rrc=sqrt((x(l1:l2)-ax)**2+(y(m)-ay)**2+(z(n)-az)**2) + tini
!           
         g_companion=-gp*rrc**(nc-1) &
              *(rrc**nc+b**nc)**(-1./nc-1.)
!
         ggc(:,1) = (x(l1:l2)-ax)/rrc*g_companion 
         ggc(:,2) = (y(  m  )-ay)/rrc*g_companion
         ggc(:,3) = (z(  n  )-az)/rrc*g_companion
!
      endif
!
!  Star's gravity field
!
      if (lcylindrical) then
         rrs=sqrt((x(l1:l2)-axs)**2+(y(m)-ays)**2)+tini
      else
         rrs=sqrt((x(l1:l2)-axs)**2+(y(m)-ays)**2+(z(n)-azs)**2) + tini
      endif
!      
!  gravity_star will call the ramped mass from inside again
!
      if (gc.ne.0) then
         call gravity_star(g0,r0_pot,n_pot,g_star,axs,ays,azs)
      else
         call gravity_star(g0,r0_pot,n_pot,g_star)
      endif
!
      ggs(:,1) = (x(l1:l2)-axs)/rrs*g_star
      ggs(:,2) = (y(  m  )-ays)/rrs*g_star
      ggs(:,3) = (z(  n  )-azs)/rrs*g_star     
      if (lcylindrical) ggs(:,3) = 0.
!
!  Reset gravity as global variable 
!  In the future, compute only potential and call grav=grad(pot)
!      
      call set_global(ggs+ggc,m,n,'gg',nx)
!
!  Add force on planet and star due to disk gravity
!
      if (lmigrate) call gravity_disk(fp,dfp,p,r0_pot)
!      
!  Stuff for calc_torque. Should maybe change it to particles_planet
!
      if (ldiagnos) then
         if ((idiag_torqint/=0) .or. (idiag_torqext/=0)) &
              call calc_torque(p%rho,gp,ax,ay,b)
         
         if ((idiag_totenergy/=0).or.(idiag_totangmom/=0) &
              .or.idiag_totmass2/=0) &
              call calc_monitored(f,axs,ays,ax,ay,gs,gp,r0_pot,p)
      endif
      lfirstcall=.false.
!
    endsubroutine gravity_companion
!***********************************************************************
    subroutine calc_torque(dens,gp,ax,ay,b)
!
! 05-nov-05/wlad : coded
!
      use Sub
!
      real, dimension(nx) :: torque,torqint,torqext
      real, dimension(nx) :: r,re,rpre,dens
      real :: b,ax,ay,Rc,roche,gp
      integer :: i
!
! Planet's hills radius
!
      Rc = sqrt(ax**2 + ay**2)
      roche = Rc*(gp/3.)**(1./3.)
!
      r  = sqrt(x(l1:l2)**2 + y(m)**2)
      re = sqrt((x(l1:l2)-ax)**2 + (y(m)-ay)**2)
      rpre = ax*y(m) - ay*x(l1:l2)
!
      torque = gp*dens*rpre*(re**2+b**2)**(-1.5)
!
      torqext=0.
      torqint=0.
!
      do i=1,nx
!
! Exclude material from inside the Roche Lobe
!
         if (re(i).ge.roche) then
!
! External torque
!
            if (r(i).ge.Rc) torqext(i) = torque(i)
!
! Internal torque
!
            if (r(i).le.Rc) torqint(i) = torque(i)
!
         endif
      enddo
!
      call sum_lim_mn_name(torqext,idiag_torqext)
      call sum_lim_mn_name(torqint,idiag_torqint)
!
    endsubroutine calc_torque
!***********************************************************************
    subroutine get_ramped_mass(gp,gs,g0,mdot,m2dot)
!      
! Ramps up the mass of the planet from 0 to gc over
! n_periods orbits. If lramp=.false., will return gc.
! Currently just used for the comparison
! project. Called by both gravity_companion and dvvp_dt 
!
! 03-mar-06/wlad : coded
!
      real :: fgp,gp,gs,g0,tcut
      real :: mdot,m2dot
!
      intent(out) :: gp,gs,mdot,m2dot
!
      fgp = 0.5*(1 - sqrt(1-4*gc))
      gp = fgp

      mdot=0. ; m2dot=0.
!
      if (lramp) then
         tcut = n_periods * 2*pi
         if (t .le. tcut) then
            gp = fgp* (sin(pi/2. * t/tcut))**2
!            
            mdot  = 0.5*fgp* pi/tcut      * sin(pi*t/tcut)
            m2dot = 0.5*fgp*(pi/tcut)**2  * cos(pi*t/tcut)
!
         endif
      endif      
!
      gs = g0 - gp
!
    endsubroutine get_ramped_mass
!***********************************************************
    subroutine wave_damping(f,df)
!
! 05-nov-05/wlad : coded
!
! Wave killing zone. Its only purpose is to have the same 
! specifications as Miguel's setup for the comparison project.
!
! As far as I understand, this thing is just like udamping 
! but with a varying pdamp, in the form of
! a parabola y=a*x**2 + c. Performs like freezing in the sense
! that it does not change the derivative in the boundary of the
! physical zone. But it does not stop the material completely
! in the outer boundary of the freezing ring.
!
!
      real, dimension(mx,my,mz,mvar+maux) :: f
      real, dimension(mx,my,mz,mvar) :: df
      integer ider,j,k,i,ii
      real, dimension(nx) :: r,pdamp,aux0,velx0,vely0
      real :: tau,lnrho_cte
!
      if (headtt) print*,&
           'wave_damping: damping motions for inner and outer boundary'
!
      tau = 2*pi/(0.4)**(-1.5)
      r = sqrt(x(l1:l2)**2 + y(m)**2)
!
      if (ldnolog) then
         lnrho_cte = 1.
      else
         lnrho_cte = 0.
      endif
!     
! for 0.4 : 1 ; 0.5 : 0
!
      pdamp = -11.111111*r**2 + 2.77777778  !parabolic function R
!
! for 0.4 : 0 ; 0.5 : 1
! pdamp = 11.1111111*r**2 - 1.777777778  
!      
      where (r .le. 0.4) 
         pdamp = 1.
      endwhere
      where (r .ge. 0.5)
         pdamp = 0.
      endwhere
!      
! aux0 is omega2
!           
      aux0 = (r**2+0.1**2)**(-1.5) 
!      
! initial conditions
!
      velx0 = -y(  m  ) * sqrt(aux0)   
      vely0 =  x(l1:l2) * sqrt(aux0)
!      
      do i=l1,l2
         ii = i-l1+1
         if ((r(ii).le.0.5).and.(r(ii).gt.0.4)) then
            df(i,m,n,ilnrho) = df(i,m,n,ilnrho) - (f(i,m,n,ilnrho) - lnrho_cte)/tau * pdamp(ii) 
            df(i,m,n,iux)    = df(i,m,n,iux)    - (f(i,m,n,iux)    - velx0(ii))/tau * pdamp(ii)
            df(i,m,n,iuy)    = df(i,m,n,iuy)    - (f(i,m,n,iuy)    - vely0(ii))/tau * pdamp(ii)
            if (nzgrid/=1) df(i,m,n,iuz) = df(i,m,n,iuz) - (f(i,m,n,iuz) - 0.)/tau * pdamp(ii)
            if (lmagnetic) then
               df(i,m,n,iax)    = df(i,m,n,iax)    - (f(i,m,n,iax) - 0.)/tau * pdamp(ii)
               df(i,m,n,iay)    = df(i,m,n,iay)    - (f(i,m,n,iay) - 0.)/tau * pdamp(ii)
               if (nzgrid/=1) df(i,m,n,iaz) = df(i,m,n,iaz) - (f(i,m,n,iaz) - 0.)/tau * pdamp(ii)
            endif
         endif
      enddo
!     
! Outer boundary
!     
     tau = 2*pi/(2.5)**(-1.5)
!     
! for 2.1 : 0 , 2.5 : 1
!
     pdamp = 0.543478*r**2 - 2.3967391  !parabolic function R
!
! for 2.1 : 1, 2.5 : 0
! pdamp = -0.543478*r**2 + 3.3967375
!     
     where (r .ge. 2.5) 
        pdamp = 1.
     endwhere
     where (r .le. 2.1)
        pdamp = 0.
     endwhere
!     
     do i=l1,l2
        ii = i-l1+1
        if ((r(ii) .ge. 2.1).and.(r(ii).le.2.5)) then
           df(i,m,n,ilnrho) = df(i,m,n,ilnrho) - (f(i,m,n,ilnrho) - lnrho_cte)/tau * pdamp(ii) 
           df(i,m,n,iux)    = df(i,m,n,iux)    - (f(i,m,n,iux)    - velx0(ii))/tau * pdamp(ii)
           df(i,m,n,iuy)    = df(i,m,n,iuy)    - (f(i,m,n,iuy)    - vely0(ii))/tau * pdamp(ii)
           if (nzgrid/=1) df(i,m,n,iuz) = df(i,m,n,iuz) - (f(i,m,n,iuz) - 0.)/tau * pdamp(ii)
           if (lmagnetic) then
              df(i,m,n,iax)    = df(i,m,n,iax)    - (f(i,m,n,iax) - 0.)/tau * pdamp(ii)
              df(i,m,n,iay)    = df(i,m,n,iay)    - (f(i,m,n,iay) - 0.)/tau * pdamp(ii)
              if (nzgrid/=1) df(i,m,n,iaz) = df(i,m,n,iaz) - (f(i,m,n,iaz) - 0.)/tau * pdamp(ii)
           endif
        endif
     enddo
!
   endsubroutine wave_damping
!***************************************************************
   subroutine gravity_star(g0,r0_pot,n_pot,g_r,xstar,ystar,zstar)
!
! 08-nov-05/wlad : coded
!
     use Mpicomm, only : stop_it
!
     real, dimension (nx), intent(out) :: g_r
     real, dimension (nx) :: rr_mn
     real, optional :: xstar,ystar,zstar !initial position of star
     integer :: i,n_pot
     real :: g0,axs,ays,azs,r0_pot,gp,gs,mdot,m2dot
!
     if (present(xstar)) then;axs=xstar;else;axs=0.;endif
     if (present(ystar)) then;ays=ystar;else;ays=0.;endif
     if (present(zstar)) then;azs=zstar;else;azs=0.;endif
!  
        if (lcylindrical) then
           rr_mn = sqrt((x(l1:l2)-axs)**2 + (y(m)-ays)**2) + tini
        else
           rr_mn = sqrt((x(l1:l2)-axs)**2 + (y(m)-ays)**2 + (z(n)-azs)**2) + tini
        endif
!
     if (n_pot.ne.2) then
        print*,'planet: smoothed gravity used for star but smoothing lenght'
        print*,'is not equal to 2. Better stop and change, since it will lead'
        print*,'to boundary troubles as omega does not flatten properly.'
        call stop_it('')
     endif
!
     call get_ramped_mass(gp,gs,g0,mdot,m2dot)
!
     g_r=-gs*rr_mn**(n_pot-1) &
          *(rr_mn**n_pot+r0_pot**n_pot)**(-1./n_pot-1.)
!   
   endsubroutine gravity_star
!***************************************************************
   subroutine gravity_disk(fp,dfp,p,r0_pot)
!
! This routine takes care of the migration process, calculating
! the backreaction of the disk onto planet and star.
!
! 01-feb-06/wlad+anders: coded
!
! WL: Apparently, there is a difference between a real number and 
! an array of dimension=1. As mpireduce deals with arrays, I
! have to define the sums as arrays as well. 
!
     use Mpicomm
     use Particles_cdata
!
     real, dimension (mpar_loc,mpvar) :: fp,dfp 
     real, dimension(nx) :: re,grav_gas
     real, dimension(1) :: sumx_loc,sumy_loc,sumz_loc
     real, dimension(1) :: sumx,sumy,sumz
     integer :: k
     real :: r_smooth,r0_pot,dv
     type (pencil_case) :: p
!
     do k=1,npar
        if (k==2) then
           r_smooth = r0_pot !star
        else if (k==1) then
           r_smooth = b      !planet
        else 
           call stop_it('gravity_disk - more than 2 planet particles?')
        endif   
!
        re = sqrt((x(l1:l2) - fp(k,ixp))**2 &
             +    (y(  m  ) - fp(k,iyp))**2 &
             +    (z(  n  ) - fp(k,izp))**2)
!       
        dv = dx*dy
        if (nzgrid/=1) dv = dv*dz
!
        grav_gas = Gvalue*p%rho*dv*re/ &
             (re**2 + r_smooth**2)**(-1.5)
!                  
        sumx_loc(1) = sum(grav_gas * (x(l1:l2) - fp(k,ixp))/re)
        sumy_loc(1) = sum(grav_gas * (y(  m  ) - fp(k,iyp))/re)
        sumz_loc(1) = sum(grav_gas * (z(  n  ) - fp(k,izp))/re)
!                  
        call mpireduce_sum(sumx_loc,sumx,1) 
        call mpireduce_sum(sumy_loc,sumy,1) 
        call mpireduce_sum(sumz_loc,sumz,1)
!        
        if (lroot) then
           dfp(k,ivpx) = dfp(k,ivpx) + sumx(1)  
           dfp(k,ivpy) = dfp(k,ivpy) + sumy(1)
           dfp(k,ivpz) = dfp(k,ivpz) + sumz(1)
        endif
!       
     enddo               
!
   endsubroutine gravity_disk
!***************************************************************
   subroutine calc_monitored(f,xs,ys,xp,yp,gs,gp,r0_pot,p)

! calculate total energy and angular momentum
! and output their evolution as monitored variables
!
! 10-nov-05/wlad   : coded
!
     use Sub
! 
     real, dimension(mx,my,mz,mvar+maux) :: f
     real, dimension(nx) :: rstar,rplanet,r,uphi
     real, dimension(nx) :: angular_momentum
     real, dimension(nx) :: kin_energy,pot_energy,total_energy
     real :: xs,ys,xp,yp  !position of star and planet
     real :: gs,gp,r0_pot !star's and planet's mass
     real :: ang_tot,energy_tot,totmass
     integer :: i
     type (pencil_case) :: p
!
     if (headtt) print*,'planet : calculate total energy'
     if (headtt) print*,'planet : calculate total angular momentum'
!
! Calculate the total energy and integrate it
!
     rstar   = sqrt((x(l1:l2)-xs)**2 + (y(m)-ys)**2)+tini
     rplanet = sqrt((x(l1:l2)-xp)**2 + (y(m)-yp)**2)+tini
!
! Kinetic energy
!
     kin_energy = p%rho * p%u2/2.
!     
! Potential energy - uses smoothed potential
!
     pot_energy = -1.*(gs*(rstar**2+r0_pot**2)**(-1./2) &
          + gp*(rplanet**2+b**2)**(-1./2))*p%rho
!     
     total_energy = kin_energy + pot_energy  
!     
! integrate it
!
     energy_tot = -pi*(r_ext - r_int)
     call sum_lim_mn_name(total_energy,idiag_totenergy, &
          energy_tot,lnorm)
!
! Angular momentum
!
     r = sqrt(x(l1:l2)**2 + y(m)**2)+tini !this is correct: baricenter
     uphi = (-p%uu(:,1)*y(m) + p%uu(:,2)*x(l1:l2))/r
     angular_momentum = p%rho * r * uphi
!     
! integrate it
!
     ang_tot = 0.8*pi*(r_ext**2.5 - r_int**2.5)
     call sum_lim_mn_name(angular_momentum,idiag_totangmom, &
          ang_tot,lnorm)
!
! total mass
!
     totmass=pi*(r_ext**2 - r_int**2)
     call sum_lim_mn_name(p%rho,idiag_totmass2,totmass,lnorm)
!
   endsubroutine calc_monitored
!***************************************************************
   subroutine set_soundspeed
!
! Locally isothermal structure for accretion disks. 
! The energy equation is not solved,but the variation
! of temperature with radius (T ~ r-1) is crucial for the
! treatment of ad hoc alpha viscosity.
!
! The obscure coefficients were calculated with an IDL
! routine to match a 1/r fall of cs2 with a constant value
! inside r = 0.4. Have to make it general some other day. 
!
! cs = H * Omega, being H the scale height and (H/r) = cte.
!
! 25-nov-05/wlad : coded
! 
     use Global, only: set_global
!
      real, dimension (nx) :: rrp,cs2
      real :: g0=1.,r0_pot=0.2
      logical :: lheader,lfirstcall=.true.
!
!     It is better to set cs2 as a global variable than to recalculate it
!     at every timestep...
!
      lheader = headtt.and.lfirstcall.and.lroot
!
      if (lheader) print*,&
           'planet: setting sound speed as global variable'
!
      if (lcylindrical) then
         rrp = sqrt(x(l1:l2)**2 + y(m)**2) + tini
      else
         rrp = sqrt(x(l1:l2)**2 + y(m)**2 + z(n)**2) + tini
      endif   
!      
      if (lcs2_thick) then 
!
! This is for H=cs/Omega = Lz/2
!
         if (lheader) &
              print*,'set soundspeed: constant H=',Lxyz(3)/2.
!
         cs2 = g0**2 * (rrp**2 + r0_pot**2)**(-1.5) &
              *(Lxyz(3)/2.)**2
      else
!
! This one is for Mach Number = 20 everywhere 
!
         if (lheader) &
              print*,'set soundspeed: Mach=20 all over'
!
         where ((rrp.le.0.4).and.(rrp.ge.0.2)) 
         
            cs2 = 0.00749375        & 
                 +0.00679450*rrp    &
                 -0.0149310 *rrp**2 &
                 -0.0580586 *rrp**3 &
                 +0.0816006 *rrp**4 
         endwhere
!
         where (rrp.gt.0.4)
            cs2 = 0.05**2 * g0 / rrp
         endwhere
!
         where (rrp.lt.0.2) 
            cs2 = 0.008
         endwhere

      endif
!    
      call set_global(cs2,m,n,'cs2',nx)
!       
      lfirstcall=.false.
!
    endsubroutine set_soundspeed
!***************************************************************
    subroutine planet_phiavg(p)
!
      type (pencil_case) :: p
!
      if (lcalc_turb) then
!
! get the previous average to use in this timestep
!
         call get_old_average(p) 
!
! calculate the new average to use in next timestep
!
         call set_new_average(p)
!
      endif
!
    endsubroutine planet_phiavg
!*******************************************************************
    subroutine get_old_average(p)
!
      use Sub, only: calc_phiavg_general,calc_phiavg_unitvects
      use Global, only: set_global,get_global
      use Mpicomm, only: stop_it
!
      real, dimension(nx,3) :: bavg,uavg
      real, dimension(nr,3) :: bavg_coarse,uavg_coarse
      real, dimension(nx) :: rcyl
      real :: rloop_1,rloop_int,rloop_ext,rmid,rmid_1,rmid_2
      real :: dudr,dbdr,dr,step,upu,upb,dwr,u0,b0 
      integer :: i,ir,aux
      type (pencil_case) :: p
!
! Get the unit vectors
!
      rcyl = sqrt(x(l1:l2)**2 + y(m)**2)
!
      call calc_phiavg_general()
      call calc_phiavg_unitvects()
!
! in the first time step, there is no average yet 
! use the pencil value then. The same will be used
! for r_int and r_ext 
!
      if (lmagnetic) then
         bavg(:,1)=p%bb(:,1)*pomx+p%bb(:,2)*pomy 
         bavg(:,2)=p%bb(:,1)*phix+p%bb(:,2)*phiy 
         bavg(:,3)=p%bb(:,3)                    
      endif
!
      uavg(:,1)=p%uu(:,1)*pomx+p%uu(:,2)*pomy
      uavg(:,2)=p%uu(:,1)*phix+p%uu(:,2)*phiy
      uavg(:,3)=p%uu(:,3)
!         
      if (it /= 1) then
!
! get the arrays of nr points calculated in set_new_average
! in the previous time-step
!
         call get_global(uavg_coarse,'uavg',nr)
         if (lmagnetic) call get_global(bavg_coarse,'bavg',nr)
!
! expand it onto the pencil with linear interpolation
!
         step = (r_ext - r_int)/nr
!
         do i=1,nx
!
! this retrives ir, from 1 to nr
!
            ir = floor((rcyl(i)-r_int)/step) + 1 
            rloop_int = r_int + (ir-1)*step
            rloop_ext = r_int + ir*step
            rmid = 0.5*(rloop_int + rloop_ext)
            rmid_1 = rmid + step

            if ((rcyl(i) .gt. r_int).and.(rcyl(i) .le. r_ext)) then 
!
! gives problem for ir=nr because ir+1 will be out of bounds
!
               do aux=1,3
                  if (ir /= nr) then 
                     dwr = rmid_1 - rmid
                     dr = rcyl(i) - rmid
!
                     upu = uavg_coarse(ir+1,aux) - uavg_coarse(ir,aux)
                     dudr = upu/dwr
                     u0 = uavg_coarse(ir,aux)
                     uavg(i,aux) = u0 + dudr*dr
!                     
                     if (lmagnetic) then
                        upb = bavg_coarse(ir+1,aux) - bavg_coarse(ir,aux)
                        dbdr = upb/dwr
                        b0 = bavg_coarse(ir,aux)
                        bavg(i,aux) = b0 + dbdr*dr
                     endif   
!
                  endif
!
! so do it backward for ir=nr
!
                  if (ir == nr) then 
                     rmid_2 = rmid-step
                     dwr = rmid - rmid_2
                     dr = rcyl(i) - rmid
!
                     upu = uavg_coarse(ir,aux) - uavg_coarse(ir-1,aux)
                     dudr = upu/dwr
                     u0 = uavg_coarse(ir,aux)
                     uavg(i,aux) = u0 + dudr*dr
!
                     if (lmagnetic) then
                        upb = bavg_coarse(ir,aux) - bavg_coarse(ir-1,aux)
                        dbdr = upb/dwr
                        b0 = bavg_coarse(ir,aux)
                        bavg(i,aux) = b0 + dbdr*dr
                     endif
!
                  endif
               enddo
            endif  !end if r_int r_ext
!
! close pencil loop
!
         enddo
!
! end (it.ne.1)
!
      endif
!
! Store the average onto a global variable, to be read on THIS
! timestep
!
      if (lmagnetic) call set_global(bavg,m,n,'bbs',nx)
      call set_global(uavg,m,n,'uus',nx)
!
    endsubroutine get_old_average
!*******************************************************************
    subroutine set_new_average(p)
!
      use Sub, only: calc_phiavg_general,calc_phiavg_unitvects
      use Global, only: set_global
      use Mpicomm 
!
      real, dimension(nr,3) :: bavg_coarse,uavg_coarse
      real, dimension(nr) :: s_uphi,s_urad,s_uzed
      real, dimension(nr) :: s_bphi,s_brad,s_bzed
      real, dimension(nr) :: up_sum,ur_sum,uz_sum
      real, dimension(nr) :: bp_sum,br_sum,bz_sum
      real, dimension(nx) :: uphi,urad,uzed
      real, dimension(nx) :: bphi,brad,bzed
      integer, dimension(nr) :: k,ktot
      real :: step,rloop_int,rloop_ext
      integer :: ir,i
      type (pencil_case) :: p
!
      call calc_phiavg_general()
      call calc_phiavg_unitvects()
!
      urad=p%uu(:,1)*pomx+p%uu(:,2)*pomy 
      uphi=p%uu(:,1)*phix+p%uu(:,2)*phiy 
      uzed=p%uu(:,3) 
      if (lmagnetic) then
         brad=p%bb(:,1)*pomx+p%bb(:,2)*pomy
         bphi=p%bb(:,1)*phix+p%bb(:,2)*phiy
         bzed=p%bb(:,3)
      endif
!
! number of radial zones
!
      step=(r_ext - r_int)/nr
!
! each zone has its limits rloop_int and rloop_ext
!
      s_uphi=0. ; s_urad=0. ; s_uzed=0.
      if (lmagnetic) then 
         s_bphi=0. ; s_brad=0. ; s_bzed=0.
      endif
      k=0
!
      do ir=1,nr
         rloop_int = r_int + (ir-1)*step
         rloop_ext = r_int + ir*step
         do i=1,nx
            if ((rcyl_mn(i).le.rloop_ext).and.(rcyl_mn(i).ge.rloop_int)) then
!
               s_uphi(ir) = s_uphi(ir) + uphi(i)
               s_urad(ir) = s_urad(ir) + urad(i)
               s_uzed(ir) = s_uzed(ir) + uzed(i)
!               
               if (lmagnetic) then
                  s_bphi(ir) = s_bphi(ir) + bphi(i)
                  s_brad(ir) = s_brad(ir) + brad(i)
                  s_bzed(ir) = s_bzed(ir) + bzed(i)
               endif
!             
               k(ir)=k(ir)+1
!
            endif
         enddo
      enddo
!
! go filling the sums and the counter
!
      call mpireduce_sum(s_urad,ur_sum,nr)
      call mpireduce_sum(s_uphi,up_sum,nr)
      call mpireduce_sum(s_uzed,uz_sum,nr)
! 
      if (lmagnetic) then
         call mpireduce_sum(s_brad,br_sum,nr)
         call mpireduce_sum(s_bphi,bp_sum,nr)
         call mpireduce_sum(s_bzed,bz_sum,nr)
      endif
!
      call mpireduce_sum_int(k,ktot,nr)
!
! Broadcast the values
!
      call mpibcast_real(ur_sum,nr)
      call mpibcast_real(up_sum,nr)
      call mpibcast_real(uz_sum,nr)
!         
      if (lmagnetic) then
         call mpibcast_real(br_sum,nr)
         call mpibcast_real(bp_sum,nr)
         call mpibcast_real(bz_sum,nr)
      endif
!
      call mpibcast_int(ktot,nr)
!
! In the last point the sums are finalized. 
!
      if (llastpoint) then
!

!
! TEMPORARY EMERGENCY BRAKE
!
        if (any(ktot == 0)) &
            call error("set_new_average","Wlad, please fix me: ktot=0") 
!
! END OF TEMPORARY EMERGENCY BRAKE
!

         uavg_coarse(:,1)=ur_sum/ktot
         uavg_coarse(:,2)=up_sum/ktot
         uavg_coarse(:,3)=uz_sum/ktot
!
         if (lmagnetic) then
            bavg_coarse(:,1)=br_sum/ktot
            bavg_coarse(:,2)=bp_sum/ktot
            bavg_coarse(:,3)=bz_sum/ktot
         endif
!
! set the averages as global variable to use in the next timestep
! ps. these variables are raw and should be interpolated 
! to the whole radial grid later to yield better results
!
         call set_global(uavg_coarse,'uavg',nr)
         if (lmagnetic) call set_global(bavg_coarse,'bavg',nr)
!
       endif  
!       
     endsubroutine set_new_average
!***************************************************************
    subroutine rprint_planet(lreset,lwrite)
!
!  reads and registers monitoring quantities for planet-disk
!
!  06-nov-05/wlad: coded
!
      use Sub
!
      integer :: iname
      logical :: lreset,lwr
      logical, optional :: lwrite
!
      lwr = .false.
      if (present(lwrite)) lwr=lwrite
!
!  reset everything in case of reset
!  (this needs to be consistent with what is defined above!)
!
      if (lreset) then
         idiag_torqint=0
         idiag_torqext=0
         idiag_totenergy=0
         idiag_totangmom=0
         idiag_totmass2=0
      endif
!
!  iname runs through all possible names that may be listed in print.in
!
      if(lroot.and.ip<14) print*,'rprint_gravity: run through parse list'
      do iname=1,nname
         call parse_name(iname,cname(iname),cform(iname),&
              'torqint',idiag_torqint)
         call parse_name(iname,cname(iname),cform(iname),&
              'torqext',idiag_torqext)
         call parse_name(iname,cname(iname),cform(iname),&
              'totenergy',idiag_totenergy)
         call parse_name(iname,cname(iname),cform(iname),&
              'totangmom',idiag_totangmom)
         call parse_name(iname,cname(iname),cform(iname),&
              'totmass2',idiag_totmass2)
      enddo
!
!  write column, idiag_XYZ, where our variable XYZ is stored
!  idl needs this even if everything is zero
!
      if (lwr) then
        write(3,*) 'i_torqint=',idiag_torqint
        write(3,*) 'i_torqext=',idiag_torqext
        write(3,*) 'i_totenergy=',idiag_totenergy
        write(3,*) 'i_totangmom=',idiag_totangmom
        write(3,*),'i_totmass2=',idiag_totmass2
      endif
!
      if (NO_WARN) print*,lreset  !(to keep compiler quiet)
!
    endsubroutine rprint_planet
!***************************************************************
  endmodule Planet
  
